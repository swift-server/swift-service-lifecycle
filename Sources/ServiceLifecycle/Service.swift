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

/// This is the basic protocol that a service has to implement.
public protocol Service: Sendable {
    /// This indicates if the service is expected to be running for the entire duration.
    /// If a long running service is returning from the ``Service/run()-1ougx`` method it is treated
    /// as an unexpected early exit and all other services are going be cancelled.
    ///
    /// By default this is set to `true`.
    var isLongRunning: Bool { get }

    /// This method is called when the ``ServiceRunner`` is starting all the services.
    ///
    /// Concrete implementation should execute their long running work in this method such as:
    /// - Handling incoming connections and requests
    /// - Background refreshes
    func run() async throws
}
