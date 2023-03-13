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

@_spi(Testing) import ServiceLifecycle
import XCTest

final class GracefulShutdownTests: XCTestCase {
    func testWithGracefulShutdownHandler() async {
        var cont: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void> { cont = $0 }
        let continuation = cont!

        let shutdownGracefulManager = GracefulShutdownManager()
        await TaskLocals.$gracefulShutdownManager.withValue(shutdownGracefulManager) {
            await withShutdownGracefulHandler {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await stream.first { _ in true }
                    }

                    await shutdownGracefulManager.shutdownGracefully()

                    await group.waitForAll()
                }
            } onGracefulShutdown: {
                continuation.finish()
            }
        }
    }

    func testWithGracefulShutdownHandler_whenAlreadyShuttingDown() async {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        let continuation = cont!

        let shutdownGracefulManager = GracefulShutdownManager()
        await shutdownGracefulManager.shutdownGracefully()
        await TaskLocals.$gracefulShutdownManager.withValue(shutdownGracefulManager) {
            await withShutdownGracefulHandler {
                continuation.yield("operation")
            } onGracefulShutdown: {
                continuation.yield("onGracefulShutdown")
            }
        }

        var iterator = stream.makeAsyncIterator()

        await XCTAsyncAssertEqual(await iterator.next(), "onGracefulShutdown")
        await XCTAsyncAssertEqual(await iterator.next(), "operation")
    }

    func testWithGracefulShutdownHandler_whenNested() async {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        let continuation = cont!

        let shutdownGracefulManager = GracefulShutdownManager()
        await TaskLocals.$gracefulShutdownManager.withValue(shutdownGracefulManager) {
            await withShutdownGracefulHandler {
                continuation.yield("outerOperation")

                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await withShutdownGracefulHandler {
                            continuation.yield("innerOperation")
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            return ()
                        } onGracefulShutdown: {
                            continuation.yield("innerOnGracefulShutdown")
                        }
                    }
                    group.addTask {
                        await withTaskGroup(of: Void.self) { group in
                            group.addTask {
                                await withShutdownGracefulHandler {
                                    continuation.yield("innerOperation")
                                    try? await Task.sleep(nanoseconds: 500_000_000)
                                    return ()
                                } onGracefulShutdown: {
                                    continuation.yield("innerOnGracefulShutdown")
                                }
                            }
                        }
                    }

                    var iterator = stream.makeAsyncIterator()

                    await XCTAsyncAssertEqual(await iterator.next(), "outerOperation")
                    await XCTAsyncAssertEqual(await iterator.next(), "innerOperation")
                    await XCTAsyncAssertEqual(await iterator.next(), "innerOperation")

                    await shutdownGracefulManager.shutdownGracefully()

                    await XCTAsyncAssertEqual(await iterator.next(), "outerOnGracefulShutdown")
                    await XCTAsyncAssertEqual(await iterator.next(), "innerOnGracefulShutdown")
                    await XCTAsyncAssertEqual(await iterator.next(), "innerOnGracefulShutdown")
                }
            } onGracefulShutdown: {
                continuation.yield("outerOnGracefulShutdown")
            }
        }
    }

    func testWithGracefulShutdownHandler_cleansUpHandlerAfterScopeExit() async {
        final actor Foo {
            func run() async {
                await withShutdownGracefulHandler {} onGracefulShutdown: {
                    self.foo()
                }
            }

            nonisolated func foo() {}
        }
        var foo: Foo! = Foo()
        weak var weakFoo: Foo? = foo

        let shutdownGracefulManager = GracefulShutdownManager()
        await TaskLocals.$gracefulShutdownManager.withValue(shutdownGracefulManager) {
            await foo.run()

            XCTAssertNotNil(weakFoo)
            foo = nil
            XCTAssertNil(weakFoo)
        }
    }
}
