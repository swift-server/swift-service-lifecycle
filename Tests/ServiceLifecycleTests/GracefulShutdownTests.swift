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

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class GracefulShutdownTests: XCTestCase {
    func testWithGracefulShutdownHandler() async {
        var cont: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void> { cont = $0 }
        let continuation = cont!

        await testGracefulShutdown { gracefulShutdownTestTrigger in
            await withGracefulShutdownHandler {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await stream.first { _ in true }
                    }

                    gracefulShutdownTestTrigger.triggerGracefulShutdown()

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

        await testGracefulShutdown { gracefulShutdownTestTrigger in
            gracefulShutdownTestTrigger.triggerGracefulShutdown()

            _ = await withGracefulShutdownHandler {
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

        await testGracefulShutdown { gracefulShutdownTestTrigger in
            await withGracefulShutdownHandler {
                continuation.yield("outerOperation")

                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await withGracefulShutdownHandler {
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
                                await withGracefulShutdownHandler {
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

                    gracefulShutdownTestTrigger.triggerGracefulShutdown()

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
                await withGracefulShutdownHandler {
                } onGracefulShutdown: {
                    self.foo()
                }
            }

            nonisolated func foo() {}
        }
        var foo: Foo! = Foo()
        weak var weakFoo: Foo? = foo

        await testGracefulShutdown { _ in
            await foo.run()

            XCTAssertNotNil(weakFoo)
            foo = nil
            XCTAssertNil(weakFoo)
        }
    }

    func testTaskShutdownGracefully() async {
        await testGracefulShutdown { gracefulShutdownTestTrigger in
            let task = Task {
                var cont: AsyncStream<Void>.Continuation!
                let stream = AsyncStream<Void> { cont = $0 }
                let continuation = cont!

                await withGracefulShutdownHandler {
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask {
                            await stream.first { _ in true }
                        }

                        await group.waitForAll()
                    }
                } onGracefulShutdown: {
                    continuation.finish()
                }
            }

            gracefulShutdownTestTrigger.triggerGracefulShutdown()

            await task.value
        }
    }

    func testTaskGroupShutdownGracefully() async {
        await testGracefulShutdown { gracefulShutdownTestTrigger in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    var cont: AsyncStream<Void>.Continuation!
                    let stream = AsyncStream<Void> { cont = $0 }
                    let continuation = cont!

                    await withGracefulShutdownHandler {
                        await withTaskGroup(of: Void.self) { group in
                            group.addTask {
                                await stream.first { _ in true }
                            }

                            await group.waitForAll()
                        }
                    } onGracefulShutdown: {
                        continuation.finish()
                    }
                }

                gracefulShutdownTestTrigger.triggerGracefulShutdown()

                await group.waitForAll()
            }
        }
    }

    func testThrowingTaskGroupShutdownGracefully() async {
        await testGracefulShutdown { gracefulShutdownTestTrigger in
            await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var cont: AsyncStream<Void>.Continuation!
                    let stream = AsyncStream<Void> { cont = $0 }
                    let continuation = cont!

                    await withGracefulShutdownHandler {
                        await withTaskGroup(of: Void.self) { group in
                            group.addTask {
                                await stream.first { _ in true }
                            }

                            await group.waitForAll()
                        }
                    } onGracefulShutdown: {
                        continuation.finish()
                    }
                }

                gracefulShutdownTestTrigger.triggerGracefulShutdown()

                try! await group.waitForAll()
            }
        }
    }

    func testCancelWhenGracefulShutdown() async throws {
        try await testGracefulShutdown { gracefulShutdownTestTrigger in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await cancelWhenGracefulShutdown {
                        try await Task.sleep(nanoseconds: 1_000_000_000_000)
                    }
                }

                gracefulShutdownTestTrigger.triggerGracefulShutdown()

                await XCTAsyncAssertThrowsError(try await group.next()) { error in
                    XCTAssertTrue(error is CancellationError)
                }
            }
        }
    }

    func testResumesCancelWhenGracefulShutdownWithResult() async throws {
        await testGracefulShutdown { _ in
            let result = await cancelWhenGracefulShutdown {
                await Task.yield()
                return "hello"
            }

            XCTAssertEqual(result, "hello")
        }
    }

    func testIsShuttingDownGracefully() async throws {
        await testGracefulShutdown { gracefulShutdownTestTrigger in
            XCTAssertFalse(Task.isShuttingDownGracefully)

            gracefulShutdownTestTrigger.triggerGracefulShutdown()

            XCTAssertTrue(Task.isShuttingDownGracefully)
        }
    }

    @available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
    func testWaitForGracefulShutdown() async throws {
        try await testGracefulShutdown { gracefulShutdownTestTrigger in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Task.sleep(for: .milliseconds(10))
                    gracefulShutdownTestTrigger.triggerGracefulShutdown()
                }

                try await withGracefulShutdownHandler {
                    try await gracefulShutdown()
                } onGracefulShutdown: {
                    // No-op
                }

                try await group.waitForAll()
            }
        }
    }

    @available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
    func testWaitForGracefulShutdown_WhenAlreadyShutdown() async throws {
        try await testGracefulShutdown { gracefulShutdownTestTrigger in
            gracefulShutdownTestTrigger.triggerGracefulShutdown()

            try await withGracefulShutdownHandler {
                try await Task.sleep(for: .milliseconds(10))
                try await gracefulShutdown()
            } onGracefulShutdown: {
                // No-op
            }
        }
    }

    func testWaitForGracefulShutdown_Cancellation() async throws {
        do {
            try await testGracefulShutdown { _ in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await gracefulShutdown()
                    }

                    group.cancelAll()
                    try await group.waitForAll()
                }
            }
            XCTFail("Expected CancellationError to be thrown")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testWithTaskCancellationOrGracefulShutdownHandler_GracefulShutdown() async throws {
        var cont: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void> { cont = $0 }
        let continuation = cont!

        await testGracefulShutdown { gracefulShutdownTestTrigger in
            await withTaskCancellationOrGracefulShutdownHandler {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await stream.first { _ in true }
                    }

                    gracefulShutdownTestTrigger.triggerGracefulShutdown()

                    await group.waitForAll()
                }
            } onCancelOrGracefulShutdown: {
                continuation.finish()
            }
        }
    }

    func testWithTaskCancellationOrGracefulShutdownHandler_TaskCancellation() async throws {
        var cont: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void> { cont = $0 }
        let continuation = cont!

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var cancelCont: AsyncStream<CheckedContinuation<Void, Never>>.Continuation!
                let cancelStream = AsyncStream<CheckedContinuation<Void, Never>> { cancelCont = $0 }
                let cancelContinuation = cancelCont!
                await withTaskCancellationOrGracefulShutdownHandler {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        cancelContinuation.yield(cont)
                        continuation.finish()
                    }
                } onCancelOrGracefulShutdown: {
                    Task {
                        let cont = await cancelStream.first(where: { _ in true })!
                        cont.resume()
                    }
                }
            }
            // wait for task to startup
            _ = await stream.first { _ in true }
            group.cancelAll()
        }
    }

    @available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
    func testCancelWhenGracefulShutdownSurvivesCancellation() async throws {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withGracefulShutdownHandler {
                    await cancelWhenGracefulShutdown {
                        await OnlyCancellationWaiter().cancellation

                        try! await uncancellable {
                            try! await Task.sleep(for: .milliseconds(500))
                        }
                    }
                } onGracefulShutdown: {
                    XCTFail("Unexpect graceful shutdown")
                }
            }

            group.cancelAll()
        }
    }

    @available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
    func testCancelWhenGracefulShutdownSurvivesErrorThrown() async throws {
        struct MyError: Error, Equatable {}

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await withGracefulShutdownHandler {
                        try await cancelWhenGracefulShutdown {
                            await OnlyCancellationWaiter().cancellation

                            try! await uncancellable {
                                try! await Task.sleep(for: .milliseconds(500))
                            }

                            throw MyError()
                        }
                    } onGracefulShutdown: {
                        XCTFail("Unexpect graceful shutdown")
                    }
                    XCTFail("Expected to have thrown")
                } catch {
                    XCTAssertEqual(error as? MyError, MyError())
                }
            }

            group.cancelAll()
        }
    }
}

func uncancellable(_ closure: @escaping @Sendable () async throws -> Void) async throws {
    let task = Task {
        try await closure()
    }

    try await task.value
}

private actor OnlyCancellationWaiter {
    private var taskContinuation: CheckedContinuation<Void, Never>?

    @usableFromInline
    init() {}

    @usableFromInline
    var cancellation: Void {
        get async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    self.taskContinuation = continuation
                }
            } onCancel: {
                Task {
                    await self.finish()
                }
            }
        }
    }

    private func finish() {
        self.taskContinuation?.resume()
        self.taskContinuation = nil
    }
}
