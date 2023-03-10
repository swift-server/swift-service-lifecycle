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

/// A ``ServiceRunner`` is responsible for running a number of services, setting up signal handling and shutting down services in the correct order.
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
    public func run() async throws {
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
            throw ServiceRunnerError.alreadyRunning()

        case .finished:
            throw ServiceRunnerError.alreadyFinished()
        }
    }

    private func _run() async throws {
        self.logger.info(
            "Starting service lifecycle",
            metadata: [
                self.configuration.loggingConfiguration.signalsKey: "\(self.configuration.gracefulShutdownSignals)",
                self.configuration.loggingConfiguration.servicesKey: "\(self.services)",
            ]
        )

        enum ChildTaskResult {
            case serviceFinished(any Service)
            case serviceThrew(any Service, any Error)
            case signalCaught(UnixSignal)
            case signalSequenceFinished
        }

        try await withThrowingTaskGroup(of: ChildTaskResult.self) { group in
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
                        self.configuration.loggingConfiguration.serviceKey: "\(service)",
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

            var finishedServiceCount = 0

            // We are going to wait for any of the services to finish or
            // the signal sequence to throw an error.
            while !group.isEmpty {
                let result = try await group.next()

                switch result {
                case .serviceFinished(let service):
                    if service.isLongRunning {
                        // If a long running service finishes early we treat this as an unexpected
                        // early exit and have to cancel the rest of the services.
                        self.logger.error(
                            "Service finished unexpectedly",
                            metadata: [
                                self.configuration.loggingConfiguration.serviceKey: "\(service)",
                            ]
                        )

                        group.cancelAll()
                        throw ServiceRunnerError.serviceFinishedUnexpectedly()
                    } else {
                        // This service finished early but we expected it.
                        // So we are just going to wait for the next service
                        self.logger.debug(
                            "Service finished",
                            metadata: [
                                self.configuration.loggingConfiguration.serviceKey: "\(service)",
                            ]
                        )

                        // We have to keep track of how many services finished to make sure
                        // to stop when only the signal child task is left
                        finishedServiceCount += 1
                        if finishedServiceCount == self.services.count {
                            // Every service finished. We can cancel the signal handling now
                            // and return
                            group.cancelAll()
                            return
                        } else {
                            // There are still running services that we have to wait for
                            continue
                        }
                    }

                case .serviceThrew(let service, let error):
                    // One of the servers threw an error. We have to cancel everything else now.
                    self.logger.error(
                        "Service threw error. Cancelling all other services now",
                        metadata: [
                            self.configuration.loggingConfiguration.serviceKey: "\(service)",
                            self.configuration.loggingConfiguration.errorKey: "\(error)",
                        ]
                    )
                    group.cancelAll()

                    throw error

                case .signalCaught(let unixSignal):
                    // We got a signal. Let's initiate graceful shutdown in reverse order than we started the
                    // services. This allows the users to declare a hierarchy with the order they passed
                    // the services.
                    self.logger.info(
                        "Signal caught",
                        metadata: [
                            self.configuration.loggingConfiguration.signalKey: "\(unixSignal)",
                        ]
                    )

                    for service in self.services.reversed() {
                        self.logger.debug(
                            "Shutting down service",
                            metadata: [
                                self.configuration.loggingConfiguration.serviceKey: "\(service)",
                            ]
                        )

                        do {
                            try await service.shutdownGracefully()
                        } catch {
                            // If we fail to gracefully shutdown a service there is really not much left
                            // we can do besides cancelling everything.
                            self.logger.error(
                                "Service threw error while gracefully shutting down. Cancelling all other services now",
                                metadata: [
                                    self.configuration.loggingConfiguration.serviceKey: "\(service)",
                                    self.configuration.loggingConfiguration.errorKey: "\(error)",
                                ]
                            )

                            group.cancelAll()
                            throw error
                        }
                    }

                case .signalSequenceFinished:
                    // This can happen when we are either cancelling everything or
                    // when the user did not specify any shutdown signals. We just have to tolerate
                    // this.
                    continue

                case nil:
                    // This is a bit weird but I guess it can happen
                    return
                }
            }
        }

        self.logger.info(
            "Service lifecycle ended"
        )
    }
}
