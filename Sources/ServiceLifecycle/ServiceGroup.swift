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

/// A ``ServiceGroup`` is responsible for running a number of services, setting up signal handling and signalling graceful shutdown to the services.
public actor ServiceGroup: Sendable {
    /// The internal state of the ``ServiceGroup``.
    private enum State {
        /// The initial state of the group.
        case initial(services: [ServiceGroupConfiguration.ServiceConfiguration])
        /// The state once ``ServiceGroup/run()`` has been called.
        case running(
            gracefulShutdownStreamContinuation: AsyncStream<Void>.Continuation
        )
        /// The state once ``ServiceGroup/run()`` has finished.
        case finished
    }

    /// The logger.
    private let logger: Logger
    /// The logging configuration.
    private let loggingConfiguration: ServiceGroupConfiguration.LoggingConfiguration
    /// The signals that lead to graceful shutdown.
    private let gracefulShutdownSignals: [UnixSignal]
    /// The signals that lead to cancellation.
    private let cancellationSignals: [UnixSignal]
    /// The current state of the group.
    private var state: State

    /// Initializes a new ``ServiceGroup``.
    ///
    /// - Parameters:
    ///   - configuration: The group's configuration
    public init(
        configuration: ServiceGroupConfiguration
    ) {
        precondition(
            Set(configuration.gracefulShutdownSignals).isDisjoint(with: configuration.cancellationSignals),
            "Overlapping graceful shutdown and cancellation signals"
        )
        precondition(configuration.logger.label != deprecatedLoggerLabel, "Please migrate to the new initializers")
        self.state = .initial(services: configuration.services)
        self.gracefulShutdownSignals = configuration.gracefulShutdownSignals
        self.cancellationSignals = configuration.cancellationSignals
        self.logger = configuration.logger
        self.loggingConfiguration = configuration.logging
    }

    @available(*, deprecated)
    public init(
        services: [any Service],
        configuration: ServiceGroupConfiguration,
        logger: Logger
    ) {
        precondition(configuration.services.isEmpty, "Please migrate to the new initializers")
        self.state = .initial(services: Array(services.map { ServiceGroupConfiguration.ServiceConfiguration(service: $0) }))
        self.gracefulShutdownSignals = configuration.gracefulShutdownSignals
        self.cancellationSignals = configuration.cancellationSignals
        self.logger = logger
        self.loggingConfiguration = configuration.logging
    }

    /// Runs all the services by spinning up a child task per service.
    /// Furthermore, this method sets up the correct signal handlers
    /// for graceful shutdown.
    public func run(file: String = #file, line: Int = #line) async throws {
        switch self.state {
        case .initial(var services):
            guard !services.isEmpty else {
                self.state = .finished
                return
            }

            let (gracefulShutdownStream, gracefulShutdownContinuation) = AsyncStream.makeStream(of: Void.self)

            self.state = .running(
                gracefulShutdownStreamContinuation: gracefulShutdownContinuation
            )

            var potentialError: Error?
            do {
                try await self._run(
                    services: &services,
                    gracefulShutdownStream: gracefulShutdownStream
                )
            } catch {
                potentialError = error
            }

            switch self.state {
            case .initial, .finished:
                fatalError("ServiceGroup is in an invalid state \(self.state)")

            case .running:
                self.state = .finished

                if let potentialError {
                    throw potentialError
                }
            }

        case .running:
            throw ServiceGroupError.alreadyRunning(file: file, line: line)

        case .finished:
            throw ServiceGroupError.alreadyFinished(file: file, line: line)
        }
    }

    /// Triggers the graceful shutdown of all services.
    ///
    /// This method returns immediately after triggering the graceful shutdown and doesn't wait until the service have shutdown.
    public func triggerGracefulShutdown() async {
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
        case serviceFinished(service: ServiceGroupConfiguration.ServiceConfiguration, index: Int)
        case serviceThrew(service: ServiceGroupConfiguration.ServiceConfiguration, index: Int, error: any Error)
        case signalCaught(UnixSignal)
        case signalSequenceFinished
        case gracefulShutdownCaught
        case gracefulShutdownFinished
    }

    private func _run(
        services: inout [ServiceGroupConfiguration.ServiceConfiguration],
        gracefulShutdownStream: AsyncStream<Void>
    ) async throws {
        self.logger.debug(
            "Starting service lifecycle",
            metadata: [
                self.loggingConfiguration.keys.gracefulShutdownSignalsKey: "\(self.gracefulShutdownSignals)",
                self.loggingConfiguration.keys.cancellationSignalsKey: "\(self.cancellationSignals)",
                self.loggingConfiguration.keys.servicesKey: "\(services.map { $0.service })",
            ]
        )

        // Using a result here since we want a task group that has non-throwing child tasks
        // but the body itself is throwing
        let result = await withTaskGroup(of: ChildTaskResult.self, returning: Result<Void, Error>.self) { group in
            // First we have to register our signals.
            let gracefulShutdownSignals = await UnixSignalsSequence(trapping: self.gracefulShutdownSignals)
            let cancellationSignals = await UnixSignalsSequence(trapping: self.cancellationSignals)

            // This is the task that listens to graceful shutdown signals
            group.addTask {
                for await signal in gracefulShutdownSignals {
                    return .signalCaught(signal)
                }

                return .signalSequenceFinished
            }

            // This is the task that listens to cancellation signals
            group.addTask {
                for await signal in cancellationSignals {
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
            gracefulShutdownManagers.reserveCapacity(services.count)

            for (index, serviceConfiguration) in services.enumerated() {
                self.logger.debug(
                    "Starting service",
                    metadata: [
                        self.loggingConfiguration.keys.serviceKey: "\(serviceConfiguration.service)",
                    ]
                )

                let gracefulShutdownManager = GracefulShutdownManager()
                gracefulShutdownManagers.append(gracefulShutdownManager)

                // This must be addTask and not addTaskUnlessCancelled
                // because we must run all the services for the below logic to work.
                group.addTask {
                    return await TaskLocals.$gracefulShutdownManager.withValue(gracefulShutdownManager) {
                        do {
                            try await serviceConfiguration.service.run()
                            return .serviceFinished(service: serviceConfiguration, index: index)
                        } catch {
                            return .serviceThrew(service: serviceConfiguration, index: index, error: error)
                        }
                    }
                }
            }

            // We are storing the services in an optional array now. When a slot in the array is
            // empty it indicates that the service has been shutdown.
            var services = services.map { Optional($0) }

            precondition(gracefulShutdownManagers.count == services.count, "We did not create a graceful shutdown manager per service")

            // We are going to wait for any of the services to finish or
            // the signal sequence to throw an error.
            while !group.isEmpty {
                let result: ChildTaskResult? = await group.next()

                switch result {
                case .serviceFinished(let service, let index):
                    if group.isCancelled {
                        // The group is cancelled and we expect all services to finish
                        continue
                    }

                    switch service.successfulTerminationBehavior.behavior {
                    case .cancelGroup:
                        self.logger.error(
                            "Service finished unexpectedly. Cancelling group.",
                            metadata: [
                                self.loggingConfiguration.keys.serviceKey: "\(service.service)",
                            ]
                        )
                        group.cancelAll()
                        return .failure(ServiceGroupError.serviceFinishedUnexpectedly())

                    case .gracefullyShutdownGroup:
                        self.logger.error(
                            "Service finished unexpectedly. Gracefully shutting down group.",
                            metadata: [
                                self.loggingConfiguration.keys.serviceKey: "\(service.service)",
                            ]
                        )
                        services[index] = nil
                        do {
                            try await self.shutdownGracefully(
                                services: services,
                                group: &group,
                                gracefulShutdownManagers: gracefulShutdownManagers
                            )
                        } catch {
                            return .failure(error)
                        }

                    case .ignore:
                        self.logger.debug(
                            "Service finished.",
                            metadata: [
                                self.loggingConfiguration.keys.serviceKey: "\(service.service)",
                            ]
                        )
                        services[index] = nil

                        if services.allSatisfy({ $0 == nil }) {
                            self.logger.debug(
                                "All services finished."
                            )
                            group.cancelAll()
                            return .success(())
                        }
                    }

                case .serviceThrew(let service, let index, let error):
                    switch service.failureTerminationBehavior.behavior {
                    case .cancelGroup:
                        self.logger.error(
                            "Service threw error. Cancelling group.",
                            metadata: [
                                self.loggingConfiguration.keys.serviceKey: "\(service.service)",
                                self.loggingConfiguration.keys.errorKey: "\(error)",
                            ]
                        )
                        group.cancelAll()
                        return .failure(error)

                    case .gracefullyShutdownGroup:
                        self.logger.error(
                            "Service threw error. Shutting down group.",
                            metadata: [
                                self.loggingConfiguration.keys.serviceKey: "\(service.service)",
                                self.loggingConfiguration.keys.errorKey: "\(error)",
                            ]
                        )
                        services[index] = nil

                        do {
                            try await self.shutdownGracefully(
                                services: services,
                                group: &group,
                                gracefulShutdownManagers: gracefulShutdownManagers
                            )
                        } catch {
                            return .failure(error)
                        }

                    case .ignore:
                        self.logger.debug(
                            "Service threw error.",
                            metadata: [
                                self.loggingConfiguration.keys.serviceKey: "\(service.service)",
                                self.loggingConfiguration.keys.errorKey: "\(error)",
                            ]
                        )
                        services[index] = nil

                        if services.allSatisfy({ $0 == nil }) {
                            self.logger.debug(
                                "All services finished."
                            )

                            group.cancelAll()
                            return .success(())
                        }
                    }

                case .signalCaught(let unixSignal):
                    if self.gracefulShutdownSignals.contains(unixSignal) {
                        // Let's initiate graceful shutdown.
                        self.logger.debug(
                            "Signal caught. Shutting down the group.",
                            metadata: [
                                self.loggingConfiguration.keys.signalKey: "\(unixSignal)",
                            ]
                        )
                        do {
                            try await self.shutdownGracefully(
                                services: services,
                                group: &group,
                                gracefulShutdownManagers: gracefulShutdownManagers
                            )
                        } catch {
                            return .failure(error)
                        }
                    } else {
                        // Let's cancel the group.
                        self.logger.debug(
                            "Signal caught. Cancelling the group.",
                            metadata: [
                                self.loggingConfiguration.keys.signalKey: "\(unixSignal)",
                            ]
                        )

                        group.cancelAll()
                    }

                case .gracefulShutdownCaught:
                    // We got a manual or inherited graceful shutdown. Let's initiate graceful shutdown.
                    self.logger.debug("Graceful shutdown caught. Cascading shutdown to services")

                    do {
                        try await self.shutdownGracefully(
                            services: services,
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
        services: [ServiceGroupConfiguration.ServiceConfiguration?],
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
            guard let service = services[gracefulShutdownIndex] else {
                self.logger.debug(
                    "Service already finished. Skipping shutdown"
                )
                continue
            }
            self.logger.debug(
                "Triggering graceful shutdown for service",
                metadata: [
                    self.loggingConfiguration.keys.serviceKey: "\(service.service)",
                ]
            )

            gracefulShutdownManager.shutdownGracefully()

            let result = await group.next()

            switch result {
            case .serviceFinished(let service, let index):
                if group.isCancelled {
                    // The group is cancelled and we expect all services to finish
                    continue
                }

                if index == gracefulShutdownIndex {
                    // The service that we signalled graceful shutdown did exit/
                    // We can continue to the next one.
                    self.logger.debug(
                        "Service finished",
                        metadata: [
                            self.loggingConfiguration.keys.serviceKey: "\(service.service)",
                        ]
                    )
                    continue
                } else {
                    // Another service exited unexpectedly
                    self.logger.debug(
                        "Service finished unexpectedly during graceful shutdown. Cancelling all other services now",
                        metadata: [
                            self.loggingConfiguration.keys.serviceKey: "\(service.service)",
                        ]
                    )

                    group.cancelAll()
                    throw ServiceGroupError.serviceFinishedUnexpectedly()
                }

            case .serviceThrew(let service, _, let error):
                switch service.failureTerminationBehavior.behavior {
                case .cancelGroup:
                    self.logger.error(
                        "Service threw error during graceful shutdown. Cancelling group.",
                        metadata: [
                            self.loggingConfiguration.keys.serviceKey: "\(service.service)",
                            self.loggingConfiguration.keys.errorKey: "\(error)",
                        ]
                    )
                    group.cancelAll()
                    throw error

                case .gracefullyShutdownGroup, .ignore:
                    self.logger.debug(
                        "Service threw error during graceful shutdown.",
                        metadata: [
                            self.loggingConfiguration.keys.serviceKey: "\(service.service)",
                            self.loggingConfiguration.keys.errorKey: "\(error)",
                        ]
                    )

                    continue
                }

            case .signalCaught(let signal):
                if self.cancellationSignals.contains(signal) {
                    // We got signalled cancellation after graceful shutdown
                    self.logger.debug(
                        "Signal caught. Cancelling the group.",
                        metadata: [
                            self.loggingConfiguration.keys.signalKey: "\(signal)",
                        ]
                    )

                    group.cancelAll()
                }

            case .signalSequenceFinished, .gracefulShutdownCaught, .gracefulShutdownFinished:
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
