//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftServiceLifecycle open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftServiceLifecycle project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftServiceLifecycle project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import UnixSignals

/// A ``ServiceRunner`` is responsible for running a number of services, setting up signal handling and signalling graceful shutdown to the services.
public actor ServiceRunner: Sendable {
    /// The internal state of the ``ServiceRunner``.
    private enum State {
        /// The initial state of the runner.
        case initial
        /// The state once ``ServiceRunner/run()`` has been called.
        case running
        /// The state once ``ServiceRunner/run()`` has finished.
        case finished
    }

    /// The services to run.
    private let services: [any Service]
    /// The runner's configuration.
    private let configuration: ServiceRunnerConfiguration
    /// The logger.
    private let logger: Logger

    /// The current state of the runner.
    private var state: State = .initial

    /// Initializes a new ``ServiceRunner``.
    ///
    /// - Parameters:
    ///   - services: The services to run.
    ///   - configuration: The runner's configuration.
    ///   - logger: The logger.
    public init(
        services: [any Service],
        configuration: ServiceRunnerConfiguration,
        logger: Logger
    ) {
        self.services = services
        self.configuration = configuration
        self.logger = logger
    }

    /// Runs all the services by spinning up a child task per service.
    /// Furthermore, this method sets up the correct signal handlers
    /// for graceful shutdown.
    public func run(file: String = #file, line: Int = #line) async throws {
        switch self.state {
        case .initial:
            self.state = .running
            try await self._run()

            switch self.state {
            case .initial, .finished:
                fatalError("ServiceRunner is in an invalid state \(self.state)")

            case .running:
                self.state = .finished
            }

        case .running:
            throw ServiceRunnerError.alreadyRunning(file: file, line: line)

        case .finished:
            throw ServiceRunnerError.alreadyFinished(file: file, line: line)
        }
    }

    private func _run() async throws {
        self.logger.info(
            "Starting service lifecycle",
            metadata: [
                self.configuration.logging.signalsKey: "\(self.configuration.gracefulShutdownSignals)",
                self.configuration.logging.servicesKey: "\(self.services)",
            ]
        )

        enum ChildTaskResult {
            case serviceFinished(any Service)
            case serviceThrew(any Service, any Error)
            case signalCaught(UnixSignal)
            case signalSequenceFinished
        }

        let shutdownGracefullyManager = GracefulShutdownManager()
        try await TaskLocals.$gracefulShutdownManager.withValue(shutdownGracefullyManager) {
            // Using a result here since we want a task group that has non-throwing child tasks
            // but the body itself is throwing
            let result = await withTaskGroup(of: ChildTaskResult.self, returning: Result<Void, Error>.self) { group in
                // First we have to register our signals.
                let unixSignals = await UnixSignalsSequence(trapping: self.configuration.gracefulShutdownSignals)

                group.addTask {
                    for await signal in unixSignals {
                        return .signalCaught(signal)
                    }

                    return .signalSequenceFinished
                }

                for service in self.services {
                    self.logger.debug(
                        "Starting service",
                        metadata: [
                            self.configuration.logging.serviceKey: "\(service)",
                        ]
                    )

                    group.addTask {
                        do {
                            try await service.run()
                            return .serviceFinished(service)
                        } catch {
                            return .serviceThrew(service, error)
                        }
                    }
                }

                // We are going to wait for any of the services to finish or
                // the signal sequence to throw an error.
                while !group.isEmpty {
                    // No child task is actually throwing here so the try! is safe
                    let result = await group.next()

                    switch result {
                    case .serviceFinished(let service):
                        // If a long running service finishes early we treat this as an unexpected
                        // early exit and have to cancel the rest of the services.
                        self.logger.error(
                            "Service finished unexpectedly",
                            metadata: [
                                self.configuration.logging.serviceKey: "\(service)",
                            ]
                        )

                        group.cancelAll()
                        return .failure(ServiceRunnerError.serviceFinishedUnexpectedly())

                    case .serviceThrew(let service, let error):
                        // One of the servers threw an error. We have to cancel everything else now.
                        self.logger.error(
                            "Service threw error. Cancelling all other services now",
                            metadata: [
                                self.configuration.logging.serviceKey: "\(service)",
                                self.configuration.logging.errorKey: "\(error)",
                            ]
                        )
                        group.cancelAll()

                        return .failure(error)

                    case .signalCaught(let unixSignal):
                        // We got a signal. Let's initiate graceful shutdown in reverse order than we started the
                        // services. This allows the users to declare a hierarchy with the order they passed
                        // the services.
                        self.logger.info(
                            "Signal caught. Shutting down services",
                            metadata: [
                                self.configuration.logging.signalKey: "\(unixSignal)",
                            ]
                        )

                        await shutdownGracefullyManager.shutdownGracefully()

                    case .signalSequenceFinished:
                        // This can happen when we are either cancelling everything or
                        // when the user did not specify any shutdown signals. We just have to tolerate
                        // this.
                        continue

                    case nil:
                        fatalError("Invalid result from group.next(). We checked if the group is empty before and still got nil")
                    }
                }

                return .success(())
            }

            try result.get()
        }

        self.logger.info(
            "Service lifecycle ended"
        )
    }
}
