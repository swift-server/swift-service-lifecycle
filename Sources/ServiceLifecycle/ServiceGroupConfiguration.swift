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
            public var signalKey = "signal"
            /// The logging key used for logging the graceful shutdown unix signals.
            public var gracefulShutdownSignalsKey = "gracefulShutdownSignals"
            /// The logging key used for logging the cancellation unix signals.
            public var cancellationSignalsKey = "cancellationSignals"
            /// The logging key used for logging the service.
            public var serviceKey = "service"
            /// The logging key used for logging the services.
            public var servicesKey = "services"
            /// The logging key used for logging an error.
            public var errorKey = "error"

            /// Initializes a new ``ServiceGroupConfiguration/LoggingConfiguration/Keys``.
            public init() {}
        }

        /// The keys used for logging.
        public var keys = Keys()

        /// Initializes a new ``ServiceGroupConfiguration/LoggingConfiguration``.
        public init() {}
    }

    public struct ServiceConfiguration: Sendable {
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

        /// The service.
        public var service: any Service
        /// The behavior when the service returns from its `run()` method.
        public var returnBehavior: TerminationBehavior
        /// The behavior when the service throws from its `run()` method.
        public var throwBehavior: TerminationBehavior

        /// Initializes a new ``ServiceGroupConfiguration/ServiceConfiguration``.
        ///
        /// - Parameters:
        ///   - service: The service.
        ///   - returnBehavior: The behavior when the service returns from its `run()` method.
        ///   - throwBehavior: The behavior when the service throws from its `run()` method.
        public init(
            service: any Service,
            returnBehavior: TerminationBehavior = .cancelGroup,
            throwBehavior: TerminationBehavior = .cancelGroup
        ) {
            self.service = service
            self.returnBehavior = returnBehavior
            self.throwBehavior = throwBehavior
        }
    }

    /// The groups's service configurations.
    public var services: [ServiceConfiguration]

    /// The signals that lead to graceful shutdown.
    public var gracefulShutdownSignals = [UnixSignal]()

    /// The signals that lead to cancellation.
    public var cancellationSignals = [UnixSignal]()

    /// The group's logger.
    public var logger: Logger

    /// The group's logging configuration.
    public var logging = LoggingConfiguration()

    /// Initializes a new ``ServiceGroupConfiguration``.
    ///
    /// - Parameters:
    ///   - services: The groups's service configurations.
    ///   - logger: The group's logger.
    public init(
        services: [ServiceConfiguration],
        logger: Logger
    ) {
        self.services = services
        self.logging = .init()
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
        gracefulShutdownSignals: [UnixSignal] = .init(),
        cancellationSignals: [UnixSignal] = .init(),
        logger: Logger
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
        logger: Logger
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
        gracefulShutdownSignals: [UnixSignal] = .init(),
        cancellationSignals: [UnixSignal] = .init(),
        logger: Logger
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
