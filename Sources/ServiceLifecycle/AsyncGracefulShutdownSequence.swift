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

/// An async sequence that emits an element once graceful shutdown has been triggered.
///
/// This sequence is a broadcast async sequence and only produces one value and then finishes.
///
/// - Note: This sequence respects cancellation and thus is `throwing`.
@usableFromInline
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
struct AsyncGracefulShutdownSequence: AsyncSequence, Sendable {
    @usableFromInline
    typealias Element = CancellationWaiter.Reason

    @inlinable
    init() {}

    @inlinable
    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator()
    }

    @usableFromInline
    struct AsyncIterator: AsyncIteratorProtocol {
        @inlinable
        init() {}

        @inlinable
        func next() async -> Element? {
            await CancellationWaiter().wait()
        }
    }
}
