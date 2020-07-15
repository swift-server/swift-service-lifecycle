//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftServiceLifecycle open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the SwiftServiceLifecycle project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftServiceLifecycle project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import Lifecycle
import LifecycleNIOCompat
import NIO
import XCTest

final class ComponentLifecycleTests: XCTestCase {
    func testStartThenShutdown() {
        let items = (5 ... Int.random(in: 10 ... 20)).map { _ in GoodItem() }
        let lifecycle = ComponentLifecycle(label: "test")
        lifecycle.register(items)
        lifecycle.start { startError in
            XCTAssertNil(startError, "not expecting error")
            lifecycle.shutdown { shutdownErrors in
                XCTAssertNil(shutdownErrors, "not expecting error")
            }
        }
        lifecycle.wait()
        items.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testDefaultCallbackQueue() {
        let lifecycle = ComponentLifecycle(label: "test")
        var startCalls = [String]()
        var stopCalls = [String]()

        let items = (1 ... Int.random(in: 10 ... 20)).map { index -> LifecycleTask in
            let id = "item-\(index)"
            return ComponentLifecycle.Task(label: id,
                                           start: .sync {
                                               dispatchPrecondition(condition: .onQueue(.global()))
                                               startCalls.append(id)
                                           },
                                           shutdown: .sync {
                                               dispatchPrecondition(condition: .onQueue(.global()))
                                               XCTAssertTrue(startCalls.contains(id))
                                               stopCalls.append(id)
                                   })
        }
        lifecycle.register(items)

        lifecycle.start { startError in
            dispatchPrecondition(condition: .onQueue(.global()))
            XCTAssertNil(startError, "not expecting error")
            lifecycle.shutdown { shutdownErrors in
                dispatchPrecondition(condition: .onQueue(.global()))
                XCTAssertNil(shutdownErrors, "not expecting error")
            }
        }
        lifecycle.wait()
        items.forEach { item in XCTAssertTrue(startCalls.contains(item.label), "expected \(item.label) to be started") }
        items.forEach { item in XCTAssertTrue(stopCalls.contains(item.label), "expected \(item.label) to be stopped") }
    }

    func testUserDefinedCallbackQueue() {
        let lifecycle = ComponentLifecycle(label: "test")
        let testQueue = DispatchQueue(label: UUID().uuidString)
        var startCalls = [String]()
        var stopCalls = [String]()

        let items = (1 ... Int.random(in: 10 ... 20)).map { index -> LifecycleTask in
            let id = "item-\(index)"
            return ComponentLifecycle.Task(label: id,
                                           start: .sync {
                                               dispatchPrecondition(condition: .onQueue(testQueue))
                                               startCalls.append(id)
                                           },
                                           shutdown: .sync {
                                               dispatchPrecondition(condition: .onQueue(testQueue))
                                               XCTAssertTrue(startCalls.contains(id))
                                               stopCalls.append(id)
                                   })
        }
        lifecycle.register(items)

        lifecycle.start(on: testQueue) { startError in
            dispatchPrecondition(condition: .onQueue(testQueue))
            XCTAssertNil(startError, "not expecting error")
            lifecycle.shutdown { shutdownErrors in
                dispatchPrecondition(condition: .onQueue(testQueue))
                XCTAssertNil(shutdownErrors, "not expecting error")
            }
        }
        lifecycle.wait()
        items.forEach { item in XCTAssertTrue(startCalls.contains(item.label), "expected \(item.label) to be started") }
        items.forEach { item in XCTAssertTrue(stopCalls.contains(item.label), "expected \(item.label) to be stopped") }
    }

    func testShutdownWhileStarting() {
        class Item: LifecycleTask {
            let startedCallback: () -> Void
            var state = State.idle

            let label = UUID().uuidString

            init(_ startedCallback: @escaping () -> Void) {
                self.startedCallback = startedCallback
            }

            func start(_ callback: @escaping (Error?) -> Void) {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    self.state = .started
                    self.startedCallback()
                    callback(nil)
                }
            }

            func shutdown(_ callback: (Error?) -> Void) {
                self.state = .shutdown
                callback(nil)
            }

            enum State {
                case idle
                case started
                case shutdown
            }
        }
        var started = 0
        let startSempahore = DispatchSemaphore(value: 0)
        let items = (5 ... Int.random(in: 10 ... 20)).map { _ in Item {
            started += 1
            startSempahore.signal()
        } }
        let lifecycle = ComponentLifecycle(label: "test")
        lifecycle.register(items)
        lifecycle.start { _ in }
        startSempahore.wait()
        lifecycle.shutdown()
        lifecycle.wait()
        XCTAssertGreaterThan(started, 0, "expected some start")
        XCTAssertLessThan(started, items.count, "exppcts partial start")
        items.prefix(started).forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
        items.suffix(started + 1).forEach { XCTAssertEqual($0.state, .idle, "expected item to be idle, but \($0.state)") }
    }

    func testShutdownWhenIdle() {
        let lifecycle = ComponentLifecycle(label: "test")
        lifecycle.register(GoodItem())

        let sempahpore1 = DispatchSemaphore(value: 0)
        lifecycle.shutdown { errors in
            XCTAssertNil(errors)
            sempahpore1.signal()
        }
        lifecycle.wait()
        XCTAssertEqual(.success, sempahpore1.wait(timeout: .now() + 1))

        let sempahpore2 = DispatchSemaphore(value: 0)
        lifecycle.shutdown { errors in
            XCTAssertNil(errors)
            sempahpore2.signal()
        }
        lifecycle.wait()
        XCTAssertEqual(.success, sempahpore2.wait(timeout: .now() + 1))
    }

    func testShutdownWhenShutdown() {
        let lifecycle = ComponentLifecycle(label: "test")
        lifecycle.register(GoodItem())
        let sempahpore1 = DispatchSemaphore(value: 0)
        lifecycle.start { _ in
            lifecycle.shutdown { errors in
                XCTAssertNil(errors)
                sempahpore1.signal()
            }
        }
        lifecycle.wait()
        XCTAssertEqual(.success, sempahpore1.wait(timeout: .now() + 1))

        let sempahpore2 = DispatchSemaphore(value: 0)
        lifecycle.shutdown { errors in
            XCTAssertNil(errors)
            sempahpore2.signal()
        }
        lifecycle.wait()
        XCTAssertEqual(.success, sempahpore2.wait(timeout: .now() + 1))
    }

    func testShutdownDuringHangingStart() {
        let lifecycle = ComponentLifecycle(label: "test")
        let blockStartSemaphore = DispatchSemaphore(value: 0)
        var startCalls = [String]()
        var stopCalls = [String]()

        do {
            let id = UUID().uuidString
            lifecycle.register(label: id,
                               start: .sync {
                                   startCalls.append(id)
                                   blockStartSemaphore.wait()
                               },
                               shutdown: .sync {
                                   XCTAssertTrue(startCalls.contains(id))
                                   stopCalls.append(id)
                                })
        }
        do {
            let id = UUID().uuidString
            lifecycle.register(label: id,
                               start: .sync {
                                   startCalls.append(id)
                               },
                               shutdown: .sync {
                                   XCTAssertTrue(startCalls.contains(id))
                                   stopCalls.append(id)
                                })
        }
        lifecycle.start { error in
            XCTAssertNil(error)
        }
        lifecycle.shutdown()
        blockStartSemaphore.signal()
        lifecycle.wait()
        XCTAssertEqual(startCalls.count, 1)
        XCTAssertEqual(stopCalls.count, 1)
    }

    func testShutdownErrors() {
        class BadItem: LifecycleTask {
            let label = UUID().uuidString

            func start(_ callback: (Error?) -> Void) {
                callback(nil)
            }

            func shutdown(_ callback: (Error?) -> Void) {
                callback(TestError())
            }
        }

        var shutdownError: Lifecycle.ShutdownError?
        let shutdownSemaphore = DispatchSemaphore(value: 0)
        let items: [LifecycleTask] = [GoodItem(), BadItem(), BadItem(), GoodItem(), BadItem()]
        let lifecycle = ComponentLifecycle(label: "test")
        lifecycle.register(items)
        lifecycle.start { startError in
            XCTAssertNil(startError, "not expecting error")
            lifecycle.shutdown { error in
                shutdownError = error as? Lifecycle.ShutdownError
                shutdownSemaphore.signal()
            }
        }
        lifecycle.wait()
        XCTAssertEqual(.success, shutdownSemaphore.wait(timeout: .now() + 1))

        let goodItems = items.compactMap { $0 as? GoodItem }
        goodItems.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
        let badItems = items.compactMap { $0 as? BadItem }
        XCTAssertEqual(shutdownError?.errors.count, badItems.count, "expected shutdown errors")
        badItems.forEach { XCTAssert(shutdownError?.errors[$0.label] is TestError, "expected error to match") }
    }

    func testStartupErrors() {
        class BadItem: LifecycleTask {
            let label: String = UUID().uuidString

            func start(_ callback: (Error?) -> Void) {
                callback(TestError())
            }

            func shutdown(_ callback: (Error?) -> Void) {
                callback(nil)
            }
        }

        let items: [LifecycleTask] = [GoodItem(), GoodItem(), BadItem(), GoodItem()]
        let lifecycle = ComponentLifecycle(label: "test")
        lifecycle.register(items)
        lifecycle.start { error in
            XCTAssert(error is TestError, "expected error to match")
        }
        lifecycle.wait()
        let badItemIndex = items.firstIndex { $0 as? BadItem != nil }!
        items.prefix(badItemIndex).compactMap { $0 as? GoodItem }.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
        items.suffix(from: badItemIndex + 1).compactMap { $0 as? GoodItem }.forEach { XCTAssertEqual($0.state, .idle, "expected item to be idle, but \($0.state)") }
    }

    func testStartAndWait() {
        class Item: LifecycleTask {
            private let semaphore: DispatchSemaphore
            var state = State.idle

            init(_ semaphore: DispatchSemaphore) {
                self.semaphore = semaphore
            }

            let label: String = UUID().uuidString

            func start(_ callback: (Error?) -> Void) {
                self.state = .started
                self.semaphore.signal()
                callback(nil)
            }

            func shutdown(_ callback: (Error?) -> Void) {
                self.state = .shutdown
                callback(nil)
            }

            enum State {
                case idle
                case started
                case shutdown
            }
        }

        let lifecycle = ComponentLifecycle(label: "test")
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue(label: "test").asyncAfter(deadline: .now() + 0.1) {
            semaphore.wait()
            lifecycle.shutdown()
        }
        let item = Item(semaphore)
        lifecycle.register(item)
        XCTAssertNoThrow(try lifecycle.startAndWait())
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown")
    }

    func testBadStartAndWait() {
        class BadItem: LifecycleTask {
            let label: String = UUID().uuidString

            func start(_ callback: (Error?) -> Void) {
                callback(TestError())
            }

            func shutdown(_ callback: (Error?) -> Void) {
                callback(nil)
            }
        }

        let lifecycle = ComponentLifecycle(label: "test")
        lifecycle.register(GoodItem(), BadItem())
        XCTAssertThrowsError(try lifecycle.startAndWait()) { error in
            XCTAssert(error is TestError, "expected error to match")
        }
    }

    func testShutdownInOrder() {
        class Item: LifecycleTask {
            let id: String
            var result: [String]

            init(_ result: inout [String]) {
                self.id = UUID().uuidString
                self.result = result
            }

            var label: String {
                return self.id
            }

            func start(_ callback: (Error?) -> Void) {
                self.result.append(self.id)
                callback(nil)
            }

            func shutdown(_ callback: (Error?) -> Void) {
                if self.result.last == self.id {
                    _ = self.result.removeLast()
                }
                callback(nil)
            }
        }

        var result = [String]()
        let items = [Item(&result), Item(&result), Item(&result), Item(&result)]
        let lifecycle = ComponentLifecycle(label: "test")
        lifecycle.register(items)
        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssert(result.isEmpty, "expected item to be shutdown in order")
    }

    func testSync() {
        class Sync {
            let id: String
            var state = State.idle

            init() {
                self.id = UUID().uuidString
            }

            func start() {
                self.state = .started
            }

            func shutdown() {
                self.state = .shutdown
            }

            enum State {
                case idle
                case started
                case shutdown
            }
        }

        let lifecycle = ComponentLifecycle(label: "test")
        let items = (5 ... Int.random(in: 10 ... 20)).map { _ in Sync() }
        items.forEach { item in
            lifecycle.register(label: item.id, start: .sync(item.start), shutdown: .sync(item.shutdown))
        }

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        items.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testAyncBarrier() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let lifecycle = ComponentLifecycle(label: "test")

        let item1 = NIOItem(eventLoopGroup: eventLoopGroup)
        lifecycle.register(label: "item1", start: .eventLoopFuture(item1.start), shutdown: .eventLoopFuture(item1.shutdown))

        lifecycle.register(label: "blocker",
                           start: .sync { try eventLoopGroup.next().makeSucceededFuture(()).wait() },
                           shutdown: .sync { try eventLoopGroup.next().makeSucceededFuture(()).wait() })

        let item2 = NIOItem(eventLoopGroup: eventLoopGroup)
        lifecycle.register(label: "item2", start: .eventLoopFuture(item2.start), shutdown: .eventLoopFuture(item2.shutdown))

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        [item1, item2].forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testConcurrency() {
        let lifecycle = ComponentLifecycle(label: "test")
        let items = (5000 ... 10000).map { _ in GoodItem(startDelay: 0, shutdownDelay: 0) }
        let group = DispatchGroup()
        items.forEach { item in
            group.enter()
            DispatchQueue(label: "test", attributes: .concurrent).async {
                defer { group.leave() }
                lifecycle.register(item)
            }
        }
        group.wait()

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        items.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testRegisterSync() {
        class Sync {
            var state = State.idle

            func start() {
                self.state = .started
            }

            func shutdown() {
                self.state = .shutdown
            }

            enum State {
                case idle
                case started
                case shutdown
            }
        }

        let lifecycle = ComponentLifecycle(label: "test")

        let item = Sync()
        lifecycle.register(label: "test",
                           start: .sync(item.start),
                           shutdown: .sync(item.shutdown))

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterShutdownSync() {
        class Sync {
            var state = State.idle

            func start() {
                self.state = .started
            }

            func shutdown() {
                self.state = .shutdown
            }

            enum State {
                case idle
                case started
                case shutdown
            }
        }

        let lifecycle = ComponentLifecycle(label: "test")

        let item = Sync()
        lifecycle.registerShutdown(label: "test", .sync(item.shutdown))

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterAsync() {
        let lifecycle = ComponentLifecycle(label: "test")

        let item = GoodItem()
        lifecycle.register(label: "test",
                           start: .async(item.start),
                           shutdown: .async(item.shutdown))

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterShutdownAsync() {
        let lifecycle = ComponentLifecycle(label: "test")

        let item = GoodItem()
        lifecycle.registerShutdown(label: "test", .async(item.shutdown))

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterAsyncClosure() {
        let lifecycle = ComponentLifecycle(label: "test")

        let item = GoodItem()
        lifecycle.register(label: "test",
                           start: .async { callback in
                               item.start(callback)
                           },
                           shutdown: .async { callback in
                               item.shutdown(callback)
                           })

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterShutdownAsyncClosure() {
        let lifecycle = ComponentLifecycle(label: "test")

        let item = GoodItem()
        lifecycle.registerShutdown(label: "test", .async { callback in
            item.shutdown(callback)
        })

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterNIO() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let lifecycle = ComponentLifecycle(label: "test")

        let item = NIOItem(eventLoopGroup: eventLoopGroup)
        lifecycle.register(label: item.id,
                           start: .eventLoopFuture(item.start),
                           shutdown: .eventLoopFuture(item.shutdown))

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterShutdownNIO() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let lifecycle = ComponentLifecycle(label: "test")

        let item = NIOItem(eventLoopGroup: eventLoopGroup)
        lifecycle.registerShutdown(label: item.id, .eventLoopFuture(item.shutdown))

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterNIOClosure() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let lifecycle = ComponentLifecycle(label: "test")

        let item = NIOItem(eventLoopGroup: eventLoopGroup)
        lifecycle.register(label: item.id,
                           start: .eventLoopFuture {
                               print("start")
                               return item.start()
                           },
                           shutdown: .eventLoopFuture {
                               print("shutdown")
                               return item.shutdown()
                           })

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterShutdownNIOClosure() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let lifecycle = ComponentLifecycle(label: "test")

        let item = NIOItem(eventLoopGroup: eventLoopGroup)
        lifecycle.registerShutdown(label: item.id, .eventLoopFuture {
            print("shutdown")
            return item.shutdown()
        })

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testNIOFailure() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let lifecycle = ComponentLifecycle(label: "test")

        lifecycle.register(label: "test",
                           start: .eventLoopFuture { eventLoopGroup.next().makeFailedFuture(TestError()) },
                           shutdown: .eventLoopFuture { eventLoopGroup.next().makeSucceededFuture(()) })

        lifecycle.start { error in
            XCTAssert(error is TestError, "expected error to match")
            lifecycle.shutdown()
        }
        lifecycle.wait()
    }

    // this is an example of how state can be managed inside a `LifecycleItem`
    // note the use of locks in this example since there could be concurrent access issues
    // in case shutdown is called (e.g. via signal trap) during the startup sequence
    // see also `testExternalState` test case
    func testInternalState() {
        class Item {
            enum State: Equatable {
                case idle
                case starting
                case started(String)
                case shuttingDown
                case shutdown
            }

            var state = State.idle
            let stateLock = Lock()

            let queue = DispatchQueue(label: "test")

            let data: String

            init(_ data: String) {
                self.data = data
            }

            func start(callback: @escaping (Error?) -> Void) {
                self.stateLock.withLock {
                    self.state = .starting
                }
                self.queue.asyncAfter(deadline: .now() + Double.random(in: 0.01 ... 0.1)) {
                    self.stateLock.withLock {
                        self.state = .started(self.data)
                    }
                    callback(nil)
                }
            }

            func shutdown(callback: @escaping (Error?) -> Void) {
                self.stateLock.withLock {
                    self.state = .shuttingDown
                }
                self.queue.asyncAfter(deadline: .now() + Double.random(in: 0.01 ... 0.1)) {
                    self.stateLock.withLock {
                        self.state = .shutdown
                    }
                    callback(nil)
                }
            }
        }

        let expectedData = UUID().uuidString
        let item = Item(expectedData)
        let lifecycle = ComponentLifecycle(label: "test")
        lifecycle.register(label: "test",
                           start: .async(item.start),
                           shutdown: .async(item.shutdown))

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            XCTAssertEqual(item.state, .started(expectedData), "expected item to be shutdown, but \(item.state)")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    // this is an example of how state can be managed outside the `Lifecycle`
    // note the use of locks in this example since there could be concurrent access issues
    // in case shutdown is called (e.g. via signal trap) during the startup sequence
    // see also `testInternalState` test case, which is the prefered way to manage item's state
    func testExternalState() {
        enum State: Equatable {
            case idle
            case started(String)
            case shutdown
        }

        class Item {
            let queue = DispatchQueue(label: "test")

            let data: String

            init(_ data: String) {
                self.data = data
            }

            func start(callback: @escaping (String) -> Void) {
                self.queue.asyncAfter(deadline: .now() + Double.random(in: 0.01 ... 0.1)) {
                    callback(self.data)
                }
            }

            func shutdown(callback: @escaping () -> Void) {
                self.queue.asyncAfter(deadline: .now() + Double.random(in: 0.01 ... 0.1)) {
                    callback()
                }
            }
        }

        var state = State.idle
        let stateLock = Lock()

        let expectedData = UUID().uuidString
        let item = Item(expectedData)
        let lifecycle = ComponentLifecycle(label: "test")
        lifecycle.register(label: "test",
                           start: .async { callback in
                               item.start { data in
                                   stateLock.withLock {
                                       state = .started(data)
                                   }
                                   callback(nil)
                               }
                           },
                           shutdown: .async { callback in
                               item.shutdown {
                                   stateLock.withLock {
                                       state = .shutdown
                                   }
                                   callback(nil)
                               }
                            })

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            XCTAssertEqual(state, .started(expectedData), "expected item to be shutdown, but \(state)")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(state, .shutdown, "expected item to be shutdown, but \(state)")
    }
}
