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
        case running(
            gracefulShutdownStreamContinuation: AsyncStream<Void>.Continuation
        )
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
            guard !self.services.isEmpty else {
                self.state = .finished
                return
            }

            let (gracefulShutdownStream, gracefulShutdownContinuation) = AsyncStream.makeStream(of: Void.self)

            self.state = .running(
                gracefulShutdownStreamContinuation: gracefulShutdownContinuation
            )

            var potentialError: Error?
            do {
                try await self._run(gracefulShutdownStream: gracefulShutdownStream)
            } catch {
                potentialError = error
            }

            switch self.state {
            case .initial, .finished:
                fatalError("ServiceRunner is in an invalid state \(self.state)")

            case .running:
                self.state = .finished

                if let potentialError {
                    throw potentialError
                }
            }

        case .running:
            throw ServiceRunnerError.alreadyRunning(file: file, line: line)

        case .finished:
            throw ServiceRunnerError.alreadyFinished(file: file, line: line)
        }
    }

    /// Triggers the graceful shutdown of all services.
    ///
    /// This method returns immediately after triggering the graceful shutdown and doesn't wait until the service have shutdown.
    public func shutdownGracefully() async {
        switch self.state {
        case .initial:
            // We aren't even running so we can stop right away.
            self.state = .finished
            return

        case .running(let gracefulShutdownStreamContinuation):
            // We cannot transition to shuttingDown here since we are signalling over to the task
            // that runs `run`. This task is responsible for transitioning to shuttingDown since
            // there might be multiple signals racing to trigger it

            // We are going to signal the run method that graceful shutdown
            // should be triggered
            gracefulShutdownStreamContinuation.yield()
            gracefulShutdownStreamContinuation.finish()

        case .finished:
            // Already finished running so nothing to do here
            return
        }
    }

    private enum ChildTaskResult {
        case serviceFinished(service: any Service, index: Int)
        case serviceThrew(service: any Service, index: Int, error: any Error)
        case signalCaught(UnixSignal)
        case signalSequenceFinished
        case gracefulShutdownCaught
        case gracefulShutdownFinished
    }

    private func _run(gracefulShutdownStream: AsyncStream<Void>) async throws {
        self.logger.debug(
            "Starting service lifecycle",
            metadata: [
                self.configuration.logging.signalsKey: "\(self.configuration.gracefulShutdownSignals)",
                self.configuration.logging.servicesKey: "\(self.services)",
            ]
        )

        // Using a result here since we want a task group that has non-throwing child tasks
        // but the body itself is throwing
        let result = await withTaskGroup(of: ChildTaskResult.self, returning: Result<Void, Error>.self) { group in
            // First we have to register our signals.
            let unixSignals = await UnixSignalsSequence(trapping: self.configuration.gracefulShutdownSignals)

            // This is the task that listens to signals
            group.addTask {
                for await signal in unixSignals {
                    return .signalCaught(signal)
                }

                return .signalSequenceFinished
            }

            // This is the task that listens to manual graceful shutdown
            group.addTask {
                for await _ in gracefulShutdownStream {
                    return .gracefulShutdownCaught
                }

                return .gracefulShutdownFinished
            }

            // This is an optional task that listens to graceful shutdowns from the parent task
            if let _ = TaskLocals.gracefulShutdownManager {
                group.addTask {
                    for await _ in AsyncGracefulShutdownSequence() {
                        return .gracefulShutdownCaught
                    }

                    return .gracefulShutdownFinished
                }
            }

            // We have to create a graceful shutdown manager per service
            // since we want to signal them individually and wait for a single service
            // to finish before moving to the next one
            var gracefulShutdownManagers = [GracefulShutdownManager]()
            gracefulShutdownManagers.reserveCapacity(self.services.count)

            for (index, service) in self.services.enumerated() {
                self.logger.debug(
                    "Starting service",
                    metadata: [
                        self.configuration.logging.serviceKey: "\(service)",
                    ]
                )

                let gracefulShutdownManager = GracefulShutdownManager()
                gracefulShutdownManagers.append(gracefulShutdownManager)

                // This must be addTask and not addTaskUnlessCancelled
                // because we must run all the services for the below logic to work.
                group.addTask {
                    return await TaskLocals.$gracefulShutdownManager.withValue(gracefulShutdownManager) {
                        do {
                            try await service.run()
                            return .serviceFinished(service: service, index: index)
                        } catch {
                            return .serviceThrew(service: service, index: index, error: error)
                        }
                    }
                }
            }

            precondition(gracefulShutdownManagers.count == self.services.count, "We did not create a graceful shutdown manager per service")

            // We are going to wait for any of the services to finish or
            // the signal sequence to throw an error.
            while !group.isEmpty {
                let result: ChildTaskResult? = await group.next()

                switch result {
                case .serviceFinished(let service, _):
                    // If a long running service finishes early we treat this as an unexpected
                    // early exit and have to cancel the rest of the services.
                    self.logger.error(
                        "Service finished unexpectedly. Cancelling all other services now",
                        metadata: [
                            self.configuration.logging.serviceKey: "\(service)",
                        ]
                    )

                    group.cancelAll()
                    return .failure(ServiceRunnerError.serviceFinishedUnexpectedly())

                case .serviceThrew(let service, _, let error):
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
                    // We got a signal. Let's initiate graceful shutdown.
                    self.logger.debug(
                        "Signal caught. Shutting down services",
                        metadata: [
                            self.configuration.logging.signalKey: "\(unixSignal)",
                        ]
                    )

                    do {
                        try await self.shutdownGracefully(
                            group: &group,
                            gracefulShutdownManagers: gracefulShutdownManagers
                        )
                    } catch {
                        return .failure(error)
                    }

                case .gracefulShutdownCaught:
                    // We got a manual or inherited graceful shutdown. Let's initiate graceful shutdown.
                    self.logger.debug("Graceful shutdown caught. Cascading shutdown to services")

                    do {
                        try await self.shutdownGracefully(
                            group: &group,
                            gracefulShutdownManagers: gracefulShutdownManagers
                        )
                    } catch {
                        return .failure(error)
                    }

                case .signalSequenceFinished, .gracefulShutdownFinished:
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

        self.logger.debug(
            "Service lifecycle ended"
        )
        try result.get()
    }

    private func shutdownGracefully(
        group: inout TaskGroup<ChildTaskResult>,
        gracefulShutdownManagers: [GracefulShutdownManager]
    ) async throws {
        guard case .running = self.state else {
            fatalError("Unexpected state")
        }

        // We have to shutdown the services in reverse. To do this
        // we are going to signal each child task the graceful shutdown and then wait for
        // its exit.
        for (gracefulShutdownIndex, gracefulShutdownManager) in gracefulShutdownManagers.lazy.enumerated().reversed() {
            self.logger.debug(
                "Triggering graceful shutdown for service",
                metadata: [
                    self.configuration.logging.serviceKey: "\(self.services[gracefulShutdownIndex])",
                ]
            )

            await gracefulShutdownManager.shutdownGracefully()

            let result = await group.next()

            switch result {
            case .serviceFinished(let service, let index):
                if index == gracefulShutdownIndex {
                    // The service that we signalled graceful shutdown did exit/
                    // We can continue to the next one.
                    self.logger.debug(
                        "Service finished",
                        metadata: [
                            self.configuration.logging.serviceKey: "\(service)",
                        ]
                    )
                    continue
                } else {
                    // Another service exited unexpectedly
                    self.logger.debug(
                        "Service finished unexpectedly during graceful shutdown. Cancelling all other services now",
                        metadata: [
                            self.configuration.logging.serviceKey: "\(service)",
                        ]
                    )

                    group.cancelAll()
                    throw ServiceRunnerError.serviceFinishedUnexpectedly()
                }

            case .serviceThrew(let service, _, let error):
                self.logger.debug(
                    "Service threw error during graceful shutdown. Cancelling all other services now",
                    metadata: [
                        self.configuration.logging.serviceKey: "\(service)",
                        self.configuration.logging.errorKey: "\(error)",
                    ]
                )
                group.cancelAll()

                throw error

            case .signalCaught, .signalSequenceFinished, .gracefulShutdownCaught, .gracefulShutdownFinished:
                // We just have to tolerate this since signals and parent graceful shutdowns downs can race.
                continue

            case nil:
                fatalError("Invalid result from group.next().")
            }
        }

        // If we hit this then all services are shutdown. The only thing remaining
        // are the tasks that listen to the various graceful shutdown signals. We
        // just have to cancel those
        group.cancelAll()
    }
}

// This should be removed once we support Swift 5.9+
extension AsyncStream {
    fileprivate static func makeStream(
        of elementType: Element.Type = Element.self,
        bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded
    ) -> (stream: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation) {
        var continuation: AsyncStream<Element>.Continuation!
        let stream = AsyncStream<Element>(bufferingPolicy: limit) { continuation = $0 }
        return (stream: stream, continuation: continuation!)
    }
}
