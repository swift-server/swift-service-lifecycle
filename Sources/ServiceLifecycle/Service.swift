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

/// A type that represents a long-running task.
///
/// This is the protocol that a service implements.
///
/// ``ServiceGroup`` calls the asynchronous ``Service/run()`` method when it starts a service.
/// A service group expects the `run` method to stay running until the process is terminated.
/// When implementing a service, return or throw an error from `run` to indicate the service should stop.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public protocol Service: Sendable {
    /// The service group calls this method when it starts the service.
    ///
    /// Your implementation should execute its long running work in this method such as:
    /// - Handling incoming connections and requests
    /// - Background refreshes
    ///
    /// - Important: Returning or throwing from this method indicates the service should stop and causes the
    /// ``ServiceGroup`` to follow behaviors for the child tasks of all other running services specified in
    /// ``ServiceGroupConfiguration/ServiceConfiguration/successTerminationBehavior`` and
    /// ``ServiceGroupConfiguration/ServiceConfiguration/failureTerminationBehavior``.
    func run() async throws
}
