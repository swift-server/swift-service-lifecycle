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
import AsyncAlgorithms

/// A service group is responsible for running a number of services, setting up signal handling, and signalling graceful shutdown to the services.
///
/// Create a service group to collect your long running tasks together, and combine them with signal handling to allow for graceful shutdowns of those services.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public actor ServiceGroup: Sendable, Service {
    /// The internal state of the ``ServiceGroup``.
    private enum State {
        /// The initial state of the group.
        case initial(services: [ServiceGroupConfiguration.ServiceConfiguration])
        /// The state once ``ServiceGroup/run()`` has been called.
        case running(
            gracefulShutdownStreamContinuation: AsyncStream<Void>.Continuation,
            addedServiceChannel: AsyncChannel<ServiceGroupConfiguration.ServiceConfiguration>
        )
        /// The state once ``ServiceGroup/run()`` has finished.
        case finished
    }

    /// The logger.
    private let logger: Logger
    /// The logging configuration.
    private let loggingConfiguration: ServiceGroupConfiguration.LoggingConfiguration
    /// The maximum amount of time that graceful shutdown is allowed to take.
    private let maximumGracefulShutdownDuration: (secondsComponent: Int64, attosecondsComponent: Int64)?
    /// The maximum amount of time that task cancellation is allowed to take.
    private let maximumCancellationDuration: (secondsComponent: Int64, attosecondsComponent: Int64)?
    /// The signals that lead to graceful shutdown.
    private let gracefulShutdownSignals: [UnixSignal]
    /// The signals that lead to cancellation.
    private let cancellationSignals: [UnixSignal]
    /// The current state of the group.
    private var state: State

    /// Creates a service group from a service group configuration you provide.
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
        self.maximumGracefulShutdownDuration = configuration._maximumGracefulShutdownDuration
        self.maximumCancellationDuration = configuration._maximumCancellationDuration
    }

    /// Creates a service group.
    ///
    /// - Parameters:
    ///   - services: The groups's services..
    ///   - gracefulShutdownSignals: The signals that lead to graceful shutdown.
    ///   - cancellationSignals: The signals that lead to cancellation.
    ///   - logger: The group's logger.
    public init(
        services: [any Service],
        gracefulShutdownSignals: [UnixSignal] = [],
        cancellationSignals: [UnixSignal] = [],
        logger: Logger
    ) {
        let configuration = ServiceGroupConfiguration(
            services: services.map { ServiceGroupConfiguration.ServiceConfiguration(service: $0) },
            gracefulShutdownSignals: gracefulShutdownSignals,
            cancellationSignals: cancellationSignals,
            logger: logger
        )

        self.init(configuration: configuration)
    }

    /// Creates a service group.
    ///
    /// Use ``init(services:gracefulShutdownSignals:cancellationSignals:logger:)`` instead.
    @available(*, deprecated, renamed: "init(services:gracefulShutdownSignals:cancellationSignals:logger:)")
    public init(
        services: [any Service],
        configuration: ServiceGroupConfiguration,
        logger: Logger
    ) {
        precondition(configuration.services.isEmpty, "Please migrate to the new initializers")
        self.state = .initial(
            services: Array(services.map { ServiceGroupConfiguration.ServiceConfiguration(service: $0) })
        )
        self.gracefulShutdownSignals = configuration.gracefulShutdownSignals
        self.cancellationSignals = configuration.cancellationSignals
        self.logger = logger
        self.loggingConfiguration = configuration.logging
        self.maximumGracefulShutdownDuration = configuration._maximumGracefulShutdownDuration
        self.maximumCancellationDuration = configuration._maximumCancellationDuration
    }

    /// Adds a service to the group.
    ///
    /// If the group is currently running, the added service will be started immediately.
    /// If the group is gracefully shutting down, cancelling, or already finished, the added service will not be started.
    /// - Parameters:
    ///   - serviceConfiguration: The service configuration to add.
    public func addServiceUnlessShutdown(_ serviceConfiguration: ServiceGroupConfiguration.ServiceConfiguration) async {
        switch self.state {
        case var .initial(services: services):
            self.state = .initial(services: [])
            services.append(serviceConfiguration)
            self.state = .initial(services: services)

        case .running(_, let addedServiceChannel):
            await addedServiceChannel.send(serviceConfiguration)

        case .finished:
            // Since this is a best effort operation we don't have to do anything here
            return
        }
    }

    /// Adds a service to the group.
    ///
    /// If the group is currently running, the added service will be started immediately.
    /// If the group is gracefully shutting down, cancelling, or already finished, the added service will not be started.
    /// - Parameters:
    ///   - service: The service to add.
    public func addServiceUnlessShutdown(_ service: any Service) async {
        await self.addServiceUnlessShutdown(ServiceGroupConfiguration.ServiceConfiguration(service: service))
    }

    /// Runs all the services by spinning up a child task per service.
    ///
    /// Furthermore, this method sets up the correct signal handlers
    /// for graceful shutdown.
    // We normally don't use underscored attributes but we really want to use the method with
    // file and line whenever possible.
    @_disfavoredOverload
    public func run() async throws {
        try await self.run(file: #file, line: #line)
    }

    /// Runs all the services by spinning up a child task per service.
    ///
    /// Furthermore, this method sets up the correct signal handlers for graceful shutdown.
    public func run(file: String = #file, line: Int = #line) async throws {
        switch self.state {
        case .initial(var services):
            guard !services.isEmpty else {
                self.state = .finished
                return
            }

            let (gracefulShutdownStream, gracefulShutdownContinuation) = AsyncStream.makeStream(of: Void.self)
            let addedServiceChannel = AsyncChannel<ServiceGroupConfiguration.ServiceConfiguration>()

            self.state = .running(
                gracefulShutdownStreamContinuation: gracefulShutdownContinuation,
                addedServiceChannel: addedServiceChannel
            )

            var potentialError: Error?
            do {
                try await self._run(
                    services: &services,
                    gracefulShutdownStream: gracefulShutdownStream,
                    addedServiceChannel: addedServiceChannel
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

        case .running(let gracefulShutdownStreamContinuation, _):
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
        case gracefulShutdownTimedOut
        case cancellationCaught
        case newServiceAdded(ServiceGroupConfiguration.ServiceConfiguration)
    }

    private func _run(
        services: inout [ServiceGroupConfiguration.ServiceConfiguration],
        gracefulShutdownStream: AsyncStream<Void>,
        addedServiceChannel: AsyncChannel<ServiceGroupConfiguration.ServiceConfiguration>
    ) async throws {
        self.logger.debug(
            "Starting service lifecycle",
            metadata: [
                self.loggingConfiguration.keys.gracefulShutdownSignalsKey: "\(self.gracefulShutdownSignals)",
                self.loggingConfiguration.keys.cancellationSignalsKey: "\(self.cancellationSignals)",
                self.loggingConfiguration.keys.servicesKey: "\(services.map { $0.service })",
            ]
        )

        // A task that is spawned when we got cancelled or
        // we cancel the task group to keep track of a timeout.
        var cancellationTimeoutTask: Task<Void, Never>?

        // Using a result here since we want a task group that has non-throwing child tasks
        // but the body itself is throwing
        let result = try await withThrowingTaskGroup(of: ChildTaskResult.self, returning: Result<Void, Error>.self) {
            group in
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
                    for try await _ in AsyncGracefulShutdownSequence() {
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
                        self.loggingConfiguration.keys.serviceKey: "\(serviceConfiguration.service)"
                    ]
                )

                let gracefulShutdownManager = GracefulShutdownManager()
                gracefulShutdownManagers.append(gracefulShutdownManager)

                self.addServiceTask(
                    group: &group,
                    service: serviceConfiguration,
                    gracefulShutdownManager: gracefulShutdownManager,
                    index: index
                )
            }

            // We are storing the services in an optional array now. When a slot in the array is
            // empty it indicates that the service has been shutdown.
            var services = services.map { Optional($0) }

            precondition(
                gracefulShutdownManagers.count == services.count,
                "We did not create a graceful shutdown manager per service"
            )

            group.addTask {
                // This child task is waiting forever until the group gets cancelled.
                let (stream, _) = AsyncStream.makeStream(of: Void.self)
                await stream.first { _ in true }
                return .cancellationCaught
            }

            // Adds a task that listens to added services and funnels them into the task group
            self.addAddedServiceListenerTask(group: &group, channel: addedServiceChannel)

            // We are going to wait for any of the services to finish or
            // the signal sequence to throw an error.
            while !group.isEmpty {
                let result: ChildTaskResult? = try await group.next()

                switch result {
                case .newServiceAdded(let serviceConfiguration):
                    self.logger.debug(
                        "Starting added service",
                        metadata: [
                            self.loggingConfiguration.keys.serviceKey: "\(serviceConfiguration.service)"
                        ]
                    )

                    let gracefulShutdownManager = GracefulShutdownManager()
                    gracefulShutdownManagers.append(gracefulShutdownManager)
                    services.append(serviceConfiguration)

                    precondition(
                        services.count == gracefulShutdownManagers.count,
                        "Mismatch between services and graceful shutdown managers"
                    )

                    self.addServiceTask(
                        group: &group,
                        service: serviceConfiguration,
                        gracefulShutdownManager: gracefulShutdownManager,
                        index: services.count - 1
                    )

                    // Each listener task can only handle a single added service, so we must add a new listener
                    self.addAddedServiceListenerTask(
                        group: &group,
                        channel: addedServiceChannel
                    )

                case .serviceFinished(let service, let index):
                    if group.isCancelled {
                        // The group is cancelled and we expect all services to finish
                        continue
                    }

                    switch service.successTerminationBehavior.behavior {
                    case .cancelGroup:
                        self.logger.debug(
                            "Service finished unexpectedly. Cancelling group.",
                            metadata: [
                                self.loggingConfiguration.keys.serviceKey: "\(service.service)"
                            ]
                        )
                        self.cancelGroupAndSpawnTimeoutIfNeeded(
                            group: &group,
                            cancellationTimeoutTask: &cancellationTimeoutTask
                        )
                        return .failure(ServiceGroupError.serviceFinishedUnexpectedly(service: "\(service.service)"))

                    case .gracefullyShutdownGroup:
                        self.logger.debug(
                            "Service finished. Gracefully shutting down group.",
                            metadata: [
                                self.loggingConfiguration.keys.serviceKey: "\(service.service)"
                            ]
                        )
                        services[index] = nil
                        do {
                            try await self.shutdownGracefully(
                                services: &services,
                                cancellationTimeoutTask: &cancellationTimeoutTask,
                                group: &group,
                                gracefulShutdownManagers: gracefulShutdownManagers
                            )
                            return .success(())
                        } catch {
                            return .failure(error)
                        }

                    case .ignore:
                        self.logger.debug(
                            "Service finished.",
                            metadata: [
                                self.loggingConfiguration.keys.serviceKey: "\(service.service)"
                            ]
                        )
                        services[index] = nil

                        if services.allSatisfy({ $0 == nil }) {
                            self.logger.debug(
                                "All services finished."
                            )
                            self.cancelGroupAndSpawnTimeoutIfNeeded(
                                group: &group,
                                cancellationTimeoutTask: &cancellationTimeoutTask
                            )
                            return .success(())
                        }
                    }

                case .serviceThrew(let service, let index, let serviceError):
                    switch service.failureTerminationBehavior.behavior {
                    case .cancelGroup:
                        self.logger.debug(
                            "Service threw error. Cancelling group.",
                            metadata: [
                                self.loggingConfiguration.keys.serviceKey: "\(service.service)",
                                self.loggingConfiguration.keys.errorKey: "\(serviceError)",
                            ]
                        )
                        self.cancelGroupAndSpawnTimeoutIfNeeded(
                            group: &group,
                            cancellationTimeoutTask: &cancellationTimeoutTask
                        )
                        return .failure(serviceError)

                    case .gracefullyShutdownGroup:
                        self.logger.debug(
                            "Service threw error. Shutting down group.",
                            metadata: [
                                self.loggingConfiguration.keys.serviceKey: "\(service.service)",
                                self.loggingConfiguration.keys.errorKey: "\(serviceError)",
                            ]
                        )
                        services[index] = nil

                        do {
                            try await self.shutdownGracefully(
                                services: &services,
                                cancellationTimeoutTask: &cancellationTimeoutTask,
                                group: &group,
                                gracefulShutdownManagers: gracefulShutdownManagers
                            )
                            return .failure(serviceError)
                        } catch {
                            return .failure(serviceError)
                        }

                    case .ignore:
                        self.logger.debug(
                            "Service threw error.",
                            metadata: [
                                self.loggingConfiguration.keys.serviceKey: "\(service.service)",
                                self.loggingConfiguration.keys.errorKey: "\(serviceError)",
                            ]
                        )
                        services[index] = nil

                        if services.allSatisfy({ $0 == nil }) {
                            self.logger.debug(
                                "All services finished."
                            )

                            self.cancelGroupAndSpawnTimeoutIfNeeded(
                                group: &group,
                                cancellationTimeoutTask: &cancellationTimeoutTask
                            )
                            return .success(())
                        }
                    }

                case .signalCaught(let unixSignal):
                    if self.gracefulShutdownSignals.contains(unixSignal) {
                        // Let's initiate graceful shutdown.
                        self.logger.debug(
                            "Signal caught. Shutting down the group.",
                            metadata: [
                                self.loggingConfiguration.keys.signalKey: "\(unixSignal)"
                            ]
                        )
                        do {
                            try await self.shutdownGracefully(
                                services: &services,
                                cancellationTimeoutTask: &cancellationTimeoutTask,
                                group: &group,
                                gracefulShutdownManagers: gracefulShutdownManagers
                            )
                            return .success(())
                        } catch {
                            return .failure(error)
                        }
                    } else {
                        // Let's cancel the group.
                        self.logger.debug(
                            "Signal caught. Cancelling the group.",
                            metadata: [
                                self.loggingConfiguration.keys.signalKey: "\(unixSignal)"
                            ]
                        )

                        self.cancelGroupAndSpawnTimeoutIfNeeded(
                            group: &group,
                            cancellationTimeoutTask: &cancellationTimeoutTask
                        )
                    }

                case .gracefulShutdownCaught:
                    // We got a manual or inherited graceful shutdown. Let's initiate graceful shutdown.
                    self.logger.debug("Graceful shutdown caught. Cascading shutdown to services")

                    do {
                        try await self.shutdownGracefully(
                            services: &services,
                            cancellationTimeoutTask: &cancellationTimeoutTask,
                            group: &group,
                            gracefulShutdownManagers: gracefulShutdownManagers
                        )
                        return .success(())
                    } catch {
                        return .failure(error)
                    }

                case .cancellationCaught:
                    // We caught cancellation in our child task so we have to spawn
                    // our cancellation timeout task if needed
                    self.logger.debug("Caught cancellation.")
                    self.cancelGroupAndSpawnTimeoutIfNeeded(
                        group: &group,
                        cancellationTimeoutTask: &cancellationTimeoutTask
                    )

                case .signalSequenceFinished, .gracefulShutdownFinished:
                    // This can happen when we are either cancelling everything or
                    // when the user did not specify any shutdown signals. We just have to tolerate
                    // this.
                    continue

                case .gracefulShutdownTimedOut:
                    fatalError("Received gracefulShutdownTimedOut but never triggered a graceful shutdown")

                case nil:
                    fatalError(
                        "Invalid result from group.next(). We checked if the group is empty before and still got nil"
                    )
                }
            }

            return .success(())
        }

        self.logger.debug(
            "Service lifecycle ended"
        )
        cancellationTimeoutTask?.cancel()
        try result.get()
    }

    private func shutdownGracefully(
        services: inout [ServiceGroupConfiguration.ServiceConfiguration?],
        cancellationTimeoutTask: inout Task<Void, Never>?,
        group: inout ThrowingTaskGroup<ChildTaskResult, Error>,
        gracefulShutdownManagers: [GracefulShutdownManager]
    ) async throws {
        guard case let .running(_, addedServiceChannel) = self.state else {
            fatalError("Unexpected state")
        }

        // Signal to stop adding new services (it is important that no new services are added after this point)
        addedServiceChannel.finish()

        if #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *),
            let maximumGracefulShutdownDuration = self.maximumGracefulShutdownDuration
        {
            group.addTask {
                try? await Task.sleep(
                    for: Duration(
                        secondsComponent: maximumGracefulShutdownDuration.secondsComponent,
                        attosecondsComponent: maximumGracefulShutdownDuration.attosecondsComponent
                    )
                )
                return .gracefulShutdownTimedOut
            }
        }

        // We are storing the first error of a service that threw here.
        var error: Error?

        // We have to shutdown the services in reverse. To do this
        // we are going to signal each child task the graceful shutdown and then wait for
        // its exit.
        gracefulShutdownLoop: for (gracefulShutdownIndex, gracefulShutdownManager) in gracefulShutdownManagers.lazy
            .enumerated().reversed()
        {
            guard let service = services[gracefulShutdownIndex] else {
                self.logger.debug(
                    "Service already finished. Skipping shutdown"
                )
                continue gracefulShutdownLoop
            }
            self.logger.debug(
                "Triggering graceful shutdown for service",
                metadata: [
                    self.loggingConfiguration.keys.serviceKey: "\(service.service)"
                ]
            )

            gracefulShutdownManager.shutdownGracefully()

            while let result = try await group.next() {
                switch result {
                case .serviceFinished(let service, let index):
                    services[index] = nil
                    if group.isCancelled {
                        // The group is cancelled and we expect all services to finish
                        continue gracefulShutdownLoop
                    }

                    guard index == gracefulShutdownIndex else {
                        // Another service exited unexpectedly
                        self.logger.debug(
                            "Service finished unexpectedly during graceful shutdown. Cancelling all other services now",
                            metadata: [
                                self.loggingConfiguration.keys.serviceKey: "\(service.service)"
                            ]
                        )

                        self.cancelGroupAndSpawnTimeoutIfNeeded(
                            group: &group,
                            cancellationTimeoutTask: &cancellationTimeoutTask
                        )
                        throw ServiceGroupError.serviceFinishedUnexpectedly(service: "\(service.service)")
                    }
                    // The service that we signalled graceful shutdown did exit/
                    // We can continue to the next one.
                    self.logger.debug(
                        "Service finished",
                        metadata: [
                            self.loggingConfiguration.keys.serviceKey: "\(service.service)"
                        ]
                    )
                    continue gracefulShutdownLoop

                case .serviceThrew(let service, let index, let serviceError):
                    services[index] = nil
                    switch service.failureTerminationBehavior.behavior {
                    case .cancelGroup:
                        self.logger.debug(
                            "Service threw error during graceful shutdown. Cancelling group.",
                            metadata: [
                                self.loggingConfiguration.keys.serviceKey: "\(service.service)",
                                self.loggingConfiguration.keys.errorKey: "\(serviceError)",
                            ]
                        )
                        group.cancelAll()
                        throw serviceError

                    case .gracefullyShutdownGroup:
                        if error == nil {
                            error = serviceError
                        }

                        guard index == gracefulShutdownIndex else {
                            // Another service threw while we were waiting for a shutdown
                            // We have to continue the iterating the task group's result
                            self.logger.debug(
                                "Another service than the service that we were shutting down threw. Continuing with the next one.",
                                metadata: [
                                    self.loggingConfiguration.keys.serviceKey: "\(service.service)",
                                    self.loggingConfiguration.keys.errorKey: "\(serviceError)",
                                ]
                            )
                            break
                        }
                        // The service that we were shutting down right now threw. Since it's failure
                        // behaviour is to shutdown the group we can continue
                        self.logger.debug(
                            "The service that we were shutting down threw. Continuing with the next one.",
                            metadata: [
                                self.loggingConfiguration.keys.serviceKey: "\(service.service)",
                                self.loggingConfiguration.keys.errorKey: "\(serviceError)",
                            ]
                        )
                        continue gracefulShutdownLoop

                    case .ignore:
                        guard index == gracefulShutdownIndex else {
                            // Another service threw while we were waiting for a shutdown
                            // We have to continue the iterating the task group's result
                            self.logger.debug(
                                "Another service than the service that we were shutting down threw. Continuing with the next one.",
                                metadata: [
                                    self.loggingConfiguration.keys.serviceKey: "\(service.service)",
                                    self.loggingConfiguration.keys.errorKey: "\(serviceError)",
                                ]
                            )
                            break
                        }
                        // The service that we were shutting down right now threw. Since it's failure
                        // behaviour is to shutdown the group we can continue
                        self.logger.debug(
                            "The service that we were shutting down threw. Continuing with the next one.",
                            metadata: [
                                self.loggingConfiguration.keys.serviceKey: "\(service.service)",
                                self.loggingConfiguration.keys.errorKey: "\(serviceError)",
                            ]
                        )
                        continue gracefulShutdownLoop
                    }

                case .signalCaught(let signal):
                    if self.cancellationSignals.contains(signal) {
                        // We got signalled cancellation after graceful shutdown
                        self.logger.debug(
                            "Signal caught. Cancelling the group.",
                            metadata: [
                                self.loggingConfiguration.keys.signalKey: "\(signal)"
                            ]
                        )

                        self.cancelGroupAndSpawnTimeoutIfNeeded(
                            group: &group,
                            cancellationTimeoutTask: &cancellationTimeoutTask
                        )
                    }

                case .gracefulShutdownTimedOut:
                    // Gracefully shutting down took longer than the user configured
                    // so we have to escalate it now.
                    self.logger.debug(
                        "Graceful shutdown took longer than allowed by the configuration. Cancelling the group now.",
                        metadata: [
                            self.loggingConfiguration.keys.serviceKey: "\(service.service)"
                        ]
                    )
                    self.cancelGroupAndSpawnTimeoutIfNeeded(
                        group: &group,
                        cancellationTimeoutTask: &cancellationTimeoutTask
                    )

                case .cancellationCaught:
                    // We caught cancellation in our child task so we have to spawn
                    // our cancellation timeout task if needed
                    self.logger.debug("Caught cancellation.")
                    self.cancelGroupAndSpawnTimeoutIfNeeded(
                        group: &group,
                        cancellationTimeoutTask: &cancellationTimeoutTask
                    )

                case .signalSequenceFinished, .gracefulShutdownCaught, .gracefulShutdownFinished:
                    // We just have to tolerate this since signals and parent graceful shutdowns downs can race.
                    // We are going to continue the result loop since we have to wait for our service
                    // to finish.
                    break

                case .newServiceAdded:
                    // Since adding services is best effort, we simply ignore this
                    break
                }
            }
        }

        // If we hit this then all services are shutdown. The only thing remaining
        // are the tasks that listen to the various graceful shutdown signals. We
        // just have to cancel those.
        // In this case we don't have to spawn our cancellation timeout task since
        // we are sure all other child tasks are handling cancellation appropriately.
        group.cancelAll()

        // If we saw an error during graceful shutdown from a service that triggers graceful
        // shutdown on error then we have to rethrow that error now
        if let error = error {
            throw error
        }
    }

    private func cancelGroupAndSpawnTimeoutIfNeeded(
        group: inout ThrowingTaskGroup<ChildTaskResult, Error>,
        cancellationTimeoutTask: inout Task<Void, Never>?
    ) {
        guard cancellationTimeoutTask == nil else {
            // We already have a cancellation timeout task running.
            self.logger.debug(
                "Task cancellation timeout task already running."
            )
            return
        }
        group.cancelAll()

        if #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *),
            let maximumCancellationDuration = self.maximumCancellationDuration
        {
            // We have to spawn an unstructured task here because the call to our `run`
            // method might have already been cancelled and we need to protect the sleep
            // from being cancelled.
            cancellationTimeoutTask = Task {
                do {
                    self.logger.debug(
                        "Task cancellation timeout task started."
                    )
                    try await Task.sleep(
                        for: Duration(
                            secondsComponent: maximumCancellationDuration.secondsComponent,
                            attosecondsComponent: maximumCancellationDuration.attosecondsComponent
                        )
                    )
                    self.logger.debug(
                        "Cancellation took longer than allowed by the configuration."
                    )
                    fatalError("Cancellation took longer than allowed by the configuration.")
                } catch {
                    // We got cancelled so our services must have finished up.
                }
            }
        } else {
            cancellationTimeoutTask = nil
        }
    }

    private func addServiceTask(
        group: inout ThrowingTaskGroup<ChildTaskResult, Error>,
        service serviceConfiguration: ServiceGroupConfiguration.ServiceConfiguration,
        gracefulShutdownManager: GracefulShutdownManager,
        index: Int
    ) {
        // This must be addTask and not addTaskUnlessCancelled
        // because we must run all the services for the shutdown logic to work.
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

    private func addAddedServiceListenerTask(
        group: inout ThrowingTaskGroup<ChildTaskResult, Error>,
        channel: AsyncChannel<ServiceGroupConfiguration.ServiceConfiguration>
    ) {
        group.addTask {
            return await withTaskCancellationHandler {
                var iterator = channel.makeAsyncIterator()
                if let addedService = await iterator.next() {
                    return .newServiceAdded(addedService)
                }

                return .gracefulShutdownFinished
            } onCancel: {
                // Once the group is cancelled we will no longer read from the channel.
                // This will resume any suspended producer in `addServiceUnlessShutdown`.
                channel.finish()
            }
        }
    }
}

// This should be removed once we support Swift 5.9+
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
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
