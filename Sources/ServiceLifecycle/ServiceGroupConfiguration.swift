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

let deprecatedLoggerLabel = "service-lifecycle-deprecated-method-logger"

/// The configuration for the ``ServiceGroup``.
public struct ServiceGroupConfiguration: Sendable {
    /// The group's logging configuration.
    public struct LoggingConfiguration: Sendable {
        public struct Keys: Sendable {
            /// The logging key used for logging the unix signal.
            public var signalKey = "sl-signal"
            /// The logging key used for logging the graceful shutdown unix signals.
            public var gracefulShutdownSignalsKey = "sl-gracefulShutdownSignals"
            /// The logging key used for logging the cancellation unix signals.
            public var cancellationSignalsKey = "sl-cancellationSignals"
            /// The logging key used for logging the service.
            public var serviceKey = "sl-service"
            /// The logging key used for logging the services.
            public var servicesKey = "sl-services"
            /// The logging key used for logging an error.
            public var errorKey = "sl-error"

            /// Initializes a new ``ServiceGroupConfiguration/LoggingConfiguration/Keys``.
            public init() {}
        }

        /// The keys used for logging.
        public var keys = Keys()

        /// Initializes a new ``ServiceGroupConfiguration/LoggingConfiguration``.
        public init() {}
    }

    public struct ServiceConfiguration: Sendable {
        /// The behavior to follow when the service finishes its ``Service/run()`` method via returning or throwing.
        public struct TerminationBehavior: Sendable, CustomStringConvertible {
            internal enum _TerminationBehavior {
                case cancelGroup
                case gracefullyShutdownGroup
                case ignore
            }

            internal let behavior: _TerminationBehavior

            public static let cancelGroup = Self(behavior: .cancelGroup)
            public static let gracefullyShutdownGroup = Self(behavior: .gracefullyShutdownGroup)
            public static let ignore = Self(behavior: .ignore)

            public var description: String {
                switch self.behavior {
                case .cancelGroup:
                    return "cancelGroup"
                case .gracefullyShutdownGroup:
                    return "gracefullyShutdownGroup"
                case .ignore:
                    return "ignore"
                }
            }
        }

        /// The service to which the initialized configuration applies.
        public var service: any Service
        /// The behavior when the service returns from its ``Service/run()`` method.
        public var successTerminationBehavior: TerminationBehavior
        /// The behavior when the service throws from its ``Service/run()`` method.
        public var failureTerminationBehavior: TerminationBehavior

        /// Initializes a new ``ServiceGroupConfiguration/ServiceConfiguration``.
        ///
        /// - Parameters:
        ///   - service: The service to which the initialized configuration applies.
        ///   - successTerminationBehavior: The behavior when the service returns from its ``Service/run()`` method.
        ///   - failureTerminationBehavior: The behavior when the service throws from its ``Service/run()`` method.
        public init(
            service: any Service,
            successTerminationBehavior: TerminationBehavior = .cancelGroup,
            failureTerminationBehavior: TerminationBehavior = .cancelGroup
        ) {
            self.service = service
            self.successTerminationBehavior = successTerminationBehavior
            self.failureTerminationBehavior = failureTerminationBehavior
        }
    }

    /// The groups's service configurations.
    public var services: [ServiceConfiguration]

    /// The signals that lead to graceful shutdown.
    public var gracefulShutdownSignals = [UnixSignal]()

    /// The signals that lead to cancellation.
    public var cancellationSignals = [UnixSignal]()

    /// The group's logger.
    public var logger: Logger?

    /// The group's logging configuration.
    public var logging = LoggingConfiguration()

    /// The maximum amount of time that graceful shutdown is allowed to take.
    ///
    /// After this time has elapsed graceful shutdown will be escalated to task cancellation.
    @available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
    public var maximumGracefulShutdownDuration: Duration? {
        get {
            guard let maximumGracefulShutdownDuration = self._maximumGracefulShutdownDuration else {
                return nil
            }
            return .init(
                secondsComponent: maximumGracefulShutdownDuration.secondsComponent,
                attosecondsComponent: maximumGracefulShutdownDuration.attosecondsComponent
            )
        }
        set {
            if let newValue = newValue {
                self._maximumGracefulShutdownDuration = (newValue.components.seconds, newValue.components.attoseconds)
            } else {
                self._maximumGracefulShutdownDuration = nil
            }
        }
    }

    internal var _maximumGracefulShutdownDuration: (secondsComponent: Int64, attosecondsComponent: Int64)?

    /// The maximum amount of time that task cancellation is allowed to take.
    ///
    /// After this time has elapsed task cancellation will be escalated to a `fatalError`.
    ///
    /// - Important: This setting is useful to guarantee that your application will exit at some point and
    /// should be used to identify APIs that are not properly implementing task cancellation.
    @available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
    public var maximumCancellationDuration: Duration? {
        get {
            guard let maximumCancellationDuration = self._maximumCancellationDuration else {
                return nil
            }
            return .init(
                secondsComponent: maximumCancellationDuration.secondsComponent,
                attosecondsComponent: maximumCancellationDuration.attosecondsComponent
            )
        }
        set {
            if let newValue = newValue {
                self._maximumCancellationDuration = (newValue.components.seconds, newValue.components.attoseconds)
            } else {
                self._maximumCancellationDuration = nil
            }
        }
    }

    internal var _maximumCancellationDuration: (secondsComponent: Int64, attosecondsComponent: Int64)?

    /// Initializes a new ``ServiceGroupConfiguration``.
    ///
    /// - Parameters:
    ///   - services: The groups's service configurations.
    ///   - logger: The group's logger.
    public init(
        services: [ServiceConfiguration],
        logger: Logger? = nil
    ) {
        self.services = services
        self.logger = logger
    }

    /// Initializes a new ``ServiceGroupConfiguration``.
    ///
    /// - Parameters:
    ///   - services: The groups's service configurations.
    ///   - gracefulShutdownSignals: The signals that lead to graceful shutdown.
    ///   - cancellationSignals: The signals that lead to cancellation.
    ///   - logger: The group's logger.
    public init(
        services: [ServiceConfiguration],
        gracefulShutdownSignals: [UnixSignal] = [],
        cancellationSignals: [UnixSignal] = [],
        logger: Logger? = nil
    ) {
        self.services = services
        self.logger = logger
        self.gracefulShutdownSignals = gracefulShutdownSignals
        self.cancellationSignals = cancellationSignals
    }

    /// Initializes a new ``ServiceGroupConfiguration``.
    ///
    /// - Parameters:
    ///   - services: The groups's services.
    ///   - logger: The group's logger.
    public init(
        services: [Service],
        logger: Logger? = nil
    ) {
        self.services = Array(services.map { ServiceConfiguration(service: $0) })
        self.logger = logger
    }

    /// Initializes a new ``ServiceGroupConfiguration``.
    ///
    /// - Parameters:
    ///   - services: The groups's services.
    ///   - gracefulShutdownSignals: The signals that lead to graceful shutdown.
    ///   - cancellationSignals: The signals that lead to cancellation.
    ///   - logger: The group's logger.
    public init(
        services: [Service],
        gracefulShutdownSignals: [UnixSignal] = [],
        cancellationSignals: [UnixSignal] = [],
        logger: Logger? = nil
    ) {
        self.services = Array(services.map { ServiceConfiguration(service: $0) })
        self.logger = logger
        self.gracefulShutdownSignals = gracefulShutdownSignals
        self.cancellationSignals = cancellationSignals
    }

    @available(*, deprecated)
    public init(gracefulShutdownSignals: [UnixSignal]) {
        self.services = []
        self.gracefulShutdownSignals = gracefulShutdownSignals
        self.logger = Logger(label: deprecatedLoggerLabel)
    }
}
