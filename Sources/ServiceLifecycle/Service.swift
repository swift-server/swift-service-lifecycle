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
    /// This method is called when the ``ServiceRunner`` is starting all the services.
    ///
    /// Concrete implementation should execute their long running work in this method such as:
    /// - Handling incoming connections and requests
    /// - Background refreshes
    ///
    /// - Important: Returning or throwing from this method is indicating a failure of the service and will cause the ``ServiceRunner``
    /// to cancel the child tasks of all other running services.
    func run() async throws
}
