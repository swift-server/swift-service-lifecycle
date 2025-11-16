//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftServiceLifecycle open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftServiceLifecycle project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftServiceLifecycle project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import Logging

/// Service that runs a preamble closure before running a child service
public struct PreambleService<S: Service>: Service {
    let preamble: @Sendable () async throws -> Void
    let service: S

    ///  Initialize PreambleService
    /// - Parameters:
    ///   - service: Child service
    ///   - preamble: Preamble closure to run before running the service
    public init(service: S, preamble: @escaping @Sendable () async throws -> Void) {
        self.service = service
        self.preamble = preamble
    }

    public func run() async throws {
        try await preamble()
        try await service.run()
    }
}

extension PreambleService where S == ServiceGroup {
    ///  Initialize PreambleService with a child ServiceGroup
    /// - Parameters:
    ///   - services: Array of services to create ServiceGroup from
    ///   - logger: Logger used by ServiceGroup
    ///   - preamble: Preamble closure to run before starting the child services
    public init(services: [Service], logger: Logger, _ preamble: @escaping @Sendable () async throws -> Void) {
        self.init(
            service: ServiceGroup(configuration: .init(services: services, logger: logger)),
            preamble: preamble
        )
    }

    ///  Initialize PreambleService with a child ServiceGroup
    /// - Parameters:
    ///   - services: Array of service configurations to create ServiceGroup from
    ///   - logger: Logger used by ServiceGroup
    ///   - preamble: Preamble closure to run before starting the child services
    public init(
        services: [ServiceGroupConfiguration.ServiceConfiguration],
        logger: Logger,
        _ preamble: @escaping @Sendable () async throws -> Void
    ) {
        self.init(
            service: ServiceGroup(configuration: .init(services: services, logger: logger)),
            preamble: preamble
        )
    }
}
