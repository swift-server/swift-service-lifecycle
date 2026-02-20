//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftServiceLifecycle open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftServiceLifecycle project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftServiceLifecycle project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// A service that runs an asynchronous throwing closure as its implementation.
///
/// Use `ClosureService` to create a lightweight ``Service`` without defining
/// a dedicated type. The closure you provide is executed when ``run()`` is called.
///
/// ```swift
/// let service = ClosureService {
///     // Do some async work
///     try await foo()
/// }
///
/// // Run the service as normal
/// try await service.run()
/// ```
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct ClosureService: Service {
    private let closure: @Sendable () async throws -> Void

    /// Creates a new closure-based service.
    ///
    /// - Parameter closure: The asynchronous throwing closure to execute when the service is run.
    public init(_ closure: @escaping @Sendable () async throws -> Void) {
        self.closure = closure
    }

    /// Runs the service by executing the closure provided at initialization.
    ///
    /// This method awaits the result of the closure and propagates any errors it throws.
    public func run() async throws {
        try await closure()
    }
}
