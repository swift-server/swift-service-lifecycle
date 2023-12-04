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

import ServiceLifecycle
import ServiceLifecycleTestKit
import XCTest

final class AsyncCancelOnGracefulShutdownSequenceTests: XCTestCase {
    func testCancelOnGracefulShutdown_finishesWhenShutdown() async throws {
        await testGracefulShutdown { gracefulShutdownTrigger in
            let stream = AsyncStream<Int> {
                try? await Task.sleep(nanoseconds: 100_000_000)
                return 1
            }

            let (resultStream, resultContinuation) = AsyncStream<Int>.makeStream()

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await value in stream.cancelOnGracefulShutdown() {
                        resultContinuation.yield(value)
                    }
                    resultContinuation.finish()
                }

                var iterator = resultStream.makeAsyncIterator()

                await XCTAsyncAssertEqual(await iterator.next(), 1)

                gracefulShutdownTrigger.triggerGracefulShutdown()

                await XCTAsyncAssertEqual(await iterator.next(), nil)
            }
        }
    }

    func testCancelOnGracefulShutdown_finishesBaseFinishes() async throws {
        await testGracefulShutdown { _ in
            let (baseStream, baseContinuation) = AsyncStream<Int>.makeStream()
            let (resultStream, resultContinuation) = AsyncStream<Int>.makeStream()

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await value in baseStream.cancelOnGracefulShutdown() {
                        resultContinuation.yield(value)
                    }
                    resultContinuation.finish()
                }

                var iterator = resultStream.makeAsyncIterator()
                baseContinuation.yield(1)

                await XCTAsyncAssertEqual(await iterator.next(), 1)

                baseContinuation.finish()

                await XCTAsyncAssertEqual(await iterator.next(), nil)
            }
        }
    }
}

extension AsyncStream {
    fileprivate static func makeStream(
        of elementType: Element.Type = Element.self,
        bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded
    ) -> (stream: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation) {
        var continuation: AsyncStream<Element>.Continuation!
        let stream = AsyncStream<Element>(bufferingPolicy: limit) { continuation = $0 }
        return (stream: stream, continuation: continuation!)
    }
}
