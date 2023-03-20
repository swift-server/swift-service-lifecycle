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
/// This sequence is a broadcast async sequence and will only produce one value and then finish.
@usableFromInline
struct AsyncGracefulShutdownSequence: AsyncSequence, Sendable {
    @usableFromInline
    typealias Element = Void

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
            var cont: AsyncStream<Void>.Continuation!
            let stream = AsyncStream<Void> { cont = $0 }
            let continuation = cont!

            return await withTaskGroup(of: Void.self) { _ in
                await withShutdownGracefulHandler {
                    await stream.first { _ in true }
                } onGracefulShutdown: {
                    continuation.yield(())
                    continuation.finish()
                }
            }
        }
    }
}
