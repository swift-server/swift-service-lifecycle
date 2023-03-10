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

import UnixSignals

/// The configuration for the ``ServiceRunner``.
public struct ServiceRunnerConfiguration: Hashable, Sendable {
    /// The runner's logging configuration.
    public struct LoggingConfiguration: Hashable, Sendable {
        /// The logging key used for logging the unix signal.
        public var signalKey = "signal"
        /// The logging key used for logging the unix signals.
        public var signalsKey = "signals"
        /// The logging key used for logging the service.
        public var serviceKey = "service"
        /// The logging key used for logging the services.
        public var servicesKey = "services"
        /// The logging key used for logging an error.
        public var errorKey = "error"

        /// Initializes a new ``ServiceRunnerConfiguration/LoggingConfiguration-swift.struct``.
        public init() {}
    }

    /// The signals that lead to graceful shutdown.
    public var gracefulShutdownSignals: [UnixSignal]

    /// The runner's logging configuration.
    public var loggingConfiguration: LoggingConfiguration

    /// Initializes a new ``ServiceRunnerConfiguration``.
    ///
    /// - Parameter gracefulShutdownSignals: The signals that lead to graceful shutdown.
    public init(gracefulShutdownSignals: [UnixSignal] = []) {
        self.gracefulShutdownSignals = []
        self.loggingConfiguration = .init()
    }
}
