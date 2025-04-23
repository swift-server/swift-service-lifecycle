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

@_spi(TestKit) import ServiceLifecycle

/// This struct is used in testing graceful shutdown.
///
/// It is passed to the `operation` closure of the ``testGracefulShutdown(operation:)`` method and allows
/// to trigger the graceful shutdown for testing purposes.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct GracefulShutdownTestTrigger: Sendable {
    private let gracefulShutdownManager: GracefulShutdownManager

    init(gracefulShutdownManager: GracefulShutdownManager) {
        self.gracefulShutdownManager = gracefulShutdownManager
    }

    /// Triggers the graceful shutdown.
    public func triggerGracefulShutdown() {
        self.gracefulShutdownManager.shutdownGracefully()
    }
}

/// Use this method for testing your graceful shutdown behaviour.
///
/// Call the code that you want to test inside the `operation` closure and trigger the graceful shutdown by calling ``GracefulShutdownTestTrigger/triggerGracefulShutdown()``
/// on the ``GracefulShutdownTestTrigger`` that is passed to the `operation` closure.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public func testGracefulShutdown<T>(operation: (GracefulShutdownTestTrigger) async throws -> T) async rethrows -> T {
    let gracefulShutdownManager = GracefulShutdownManager()
    return try await TaskLocals.$gracefulShutdownManager.withValue(gracefulShutdownManager) {
        let gracefulShutdownTestTrigger = GracefulShutdownTestTrigger(gracefulShutdownManager: gracefulShutdownManager)
        return try await operation(gracefulShutdownTestTrigger)
    }
}
