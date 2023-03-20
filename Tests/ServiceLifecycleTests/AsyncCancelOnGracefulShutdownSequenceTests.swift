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

import AsyncAlgorithms
import ServiceLifecycle
import ServiceLifecycleTestKit
import XCTest

final class AsyncCancelOnGracefulShutdownSequenceTests: XCTestCase {
    func test() async throws {
        await testGracefulShutdown { gracefulShutdownTrigger in
            let stream = AsyncStream<Int> {
                try? await Task.sleep(nanoseconds: 100_000_000)
                return 1
            }

            var cont: AsyncStream<Int>.Continuation!
            let results = AsyncStream<Int> { cont = $0 }
            let continuation = cont!

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await value in stream.cancelOnGracefulShutdown() {
                        continuation.yield(value)
                    }
                    continuation.finish()
                }

                var iterator = results.makeAsyncIterator()

                await XCTAsyncAssertEqual(await iterator.next(), 1)

                await gracefulShutdownTrigger.triggerGracefulShutdown()

                await XCTAsyncAssertEqual(await iterator.next(), nil)
            }
        }
    }
}
