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

    func testDefaultCallbackQueue() throws {
        guard #available(OSX 10.12, *) else {
            return
        }

        let lifecycle = ComponentLifecycle(label: "test")
        var startCalls = [String]()
        var stopCalls = [String]()

        let items = (1 ... Int.random(in: 10 ... 20)).map { index -> LifecycleTask in
            let id = "item-\(index)"
            return _LifecycleTask(label: id,
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

    func testUserDefinedCallbackQueue() throws {
        guard #available(OSX 10.12, *) else {
            return
        }

        let lifecycle = ComponentLifecycle(label: "test")
        let testQueue = DispatchQueue(label: UUID().uuidString)
        var startCalls = [String]()
        var stopCalls = [String]()

        let items = (1 ... Int.random(in: 10 ... 20)).map { index -> LifecycleTask in
            let id = "item-\(index)"
            return _LifecycleTask(label: id,
                                  shutdownIfNotStarted: false,
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

    func testZeroTask() {
        let lifecycle = ComponentLifecycle(label: "test")

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
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

    func testNOOPHandlers() {
        let none = LifecycleHandler.none
        XCTAssertEqual(none.noop, true)

        let sync = LifecycleHandler.sync {}
        XCTAssertEqual(sync.noop, false)

        let async = LifecycleHandler.async { _ in }
        XCTAssertEqual(async.noop, false)

        let custom = LifecycleHandler { _ in }
        XCTAssertEqual(custom.noop, false)
    }

    func testShutdownOnlyStarted() {
        class Item {
            let label: String
            let sempahore: DispatchSemaphore
            let failStart: Bool
            let exptectedState: State
            var state = State.idle

            deinit {
                XCTAssertEqual(self.state, self.exptectedState, "\"\(self.label)\" should be \(self.exptectedState)")
                self.sempahore.signal()
            }

            init(label: String, failStart: Bool, exptectedState: State, sempahore: DispatchSemaphore) {
                self.label = label
                self.failStart = failStart
                self.exptectedState = exptectedState
                self.sempahore = sempahore
            }

            func start() throws {
                self.state = .started
                if self.failStart {
                    self.state = .error
                    throw InitError()
                }
            }

            func shutdown() throws {
                self.state = .shutdown
            }

            enum State {
                case idle
                case started
                case shutdown
                case error
            }

            struct InitError: Error {}
        }

        let count = Int.random(in: 10 ..< 20)
        let sempahore = DispatchSemaphore(value: count)
        let lifecycle = ServiceLifecycle(configuration: .init(shutdownSignal: nil))

        for index in 0 ..< count {
            let item = Item(label: "\(index)", failStart: index == count / 2, exptectedState: index <= count / 2 ? .shutdown : .idle, sempahore: sempahore)
            lifecycle.register(label: item.label, start: .sync(item.start), shutdown: .sync(item.shutdown))
        }

        lifecycle.start { error in
            XCTAssertNotNil(error, "expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()

        XCTAssertEqual(.success, sempahore.wait(timeout: .now() + 1))
    }

    func testShutdownWhenStartFailedIfAsked() {
        class DestructionSensitive {
            let label: String
            let failStart: Bool
            let sempahore: DispatchSemaphore
            var state = State.idle

            deinit {
                XCTAssertEqual(self.state, .shutdown, "\"\(self.label)\" should be shutdown")
                self.sempahore.signal()
            }

            init(label: String, failStart: Bool = false, sempahore: DispatchSemaphore) {
                self.label = label
                self.failStart = failStart
                self.sempahore = sempahore
            }

            func start() throws {
                self.state = .started
                if self.failStart {
                    self.state = .error
                    throw InitError()
                }
            }

            func shutdown() throws {
                self.state = .shutdown
            }

            enum State {
                case idle
                case started
                case shutdown
                case error
            }

            struct InitError: Error {}
        }

        let sempahore = DispatchSemaphore(value: 6)
        let lifecycle = ServiceLifecycle(configuration: .init(shutdownSignal: nil))

        let item1 = DestructionSensitive(label: "1", sempahore: sempahore)
        lifecycle.register(label: item1.label, start: .sync(item1.start), shutdown: .sync(item1.shutdown))

        let item2 = DestructionSensitive(label: "2", sempahore: sempahore)
        lifecycle.registerShutdown(label: item2.label, .sync(item2.shutdown))

        let item3 = DestructionSensitive(label: "3", failStart: true, sempahore: sempahore)
        lifecycle.register(label: item3.label, start: .sync(item3.start), shutdown: .sync(item3.shutdown))

        let item4 = DestructionSensitive(label: "4", sempahore: sempahore)
        lifecycle.registerShutdown(label: item4.label, .sync(item4.shutdown))

        let item5 = DestructionSensitive(label: "5", sempahore: sempahore)
        lifecycle.register(label: item5.label, start: .none, shutdown: .sync(item5.shutdown))

        let item6 = DestructionSensitive(label: "6", sempahore: sempahore)
        lifecycle.register(_LifecycleTask(label: item6.label, shutdownIfNotStarted: true, start: .sync(item6.start), shutdown: .sync(item6.shutdown)))

        lifecycle.start { error in
            XCTAssertNotNil(error, "expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()

        XCTAssertEqual(.success, sempahore.wait(timeout: .now() + 1))
    }

    func testStatefulSync() {
        class Item {
            let id: String = UUID().uuidString
            var shutdown: Bool = false

            func start() throws -> String {
                return self.id
            }

            func shutdown(state: String) throws {
                XCTAssertEqual(self.id, state)
                self.shutdown = true // not thread safe but okay for this purpose
            }
        }

        let lifecycle = ComponentLifecycle(label: "test")

        let item = Item()
        lifecycle.registerStateful(label: "test", start: .sync(item.start), shutdown: .sync(item.shutdown))

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertTrue(item.shutdown, "expected item to be shutdown")
    }

    func testStatefulSyncStartError() {
        class Item {
            let id: String = UUID().uuidString

            func start() throws -> String {
                throw TestError()
            }

            func shutdown(state: String) throws {
                XCTFail("should not be shutdown")
                throw TestError()
            }
        }

        let lifecycle = ComponentLifecycle(label: "test")

        let item = Item()
        lifecycle.registerStateful(label: "test", start: .sync(item.start), shutdown: .sync(item.shutdown))

        XCTAssertThrowsError(try lifecycle.startAndWait()) { error in
            XCTAssert(error is TestError, "expected error to match")
        }
    }

    func testStatefulSyncShutdownError() {
        class Item {
            let id: String = UUID().uuidString
            var shutdown: Bool = false

            func start() throws -> String {
                return self.id
            }

            func shutdown(state: String) throws {
                XCTAssertEqual(self.id, state)
                throw TestError()
            }
        }

        let lifecycle = ComponentLifecycle(label: "test")

        let item = Item()
        lifecycle.registerStateful(label: "test", start: .sync(item.start), shutdown: .sync(item.shutdown))

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown { error in
                guard let shutdownError = error as? ShutdownError else {
                    return XCTFail("expected error to match")
                }
                XCTAssertEqual(shutdownError.errors.count, 1)
                XCTAssert(shutdownError.errors.values.first! is TestError, "expected error to match")
            }
        }

        XCTAssertFalse(item.shutdown, "expected item to be shutdown")
    }

    func testStatefulAsync() {
        class Item {
            let id: String = UUID().uuidString
            var shutdown: Bool = false

            func start(_ callback: @escaping (Result<String, Error>) -> Void) {
                callback(.success(self.id))
            }

            func shutdown(state: String, _ callback: @escaping (Error?) -> Void) {
                XCTAssertEqual(self.id, state)
                self.shutdown = true // not thread safe but okay for this purpose
                callback(nil)
            }
        }

        let lifecycle = ComponentLifecycle(label: "test")

        let item = Item()
        lifecycle.registerStateful(label: "test", start: .async(item.start), shutdown: .async(item.shutdown))

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertTrue(item.shutdown, "expected item to be shutdown")
    }

    func testStatefulAsyncStartError() {
        class Item {
            let id: String = UUID().uuidString

            func start(_ callback: @escaping (Result<String, Error>) -> Void) {
                callback(.failure(TestError()))
            }

            func shutdown(state: String, _ callback: @escaping (Error?) -> Void) {
                XCTFail("should not be shutdown")
                callback(TestError())
            }
        }

        let lifecycle = ComponentLifecycle(label: "test")

        let item = Item()
        lifecycle.registerStateful(label: "test", start: .async(item.start), shutdown: .async(item.shutdown))

        XCTAssertThrowsError(try lifecycle.startAndWait()) { error in
            XCTAssert(error is TestError, "expected error to match")
        }
    }

    func testStatefulAsyncShutdownError() {
        class Item {
            let id: String = UUID().uuidString
            var shutdown: Bool = false

            func start(_ callback: @escaping (Result<String, Error>) -> Void) {
                callback(.success(self.id))
            }

            func shutdown(state: String, _ callback: @escaping (Error?) -> Void) {
                XCTAssertEqual(self.id, state)
                callback(TestError())
            }
        }

        let lifecycle = ComponentLifecycle(label: "test")

        let item = Item()
        lifecycle.registerStateful(label: "test", start: .async(item.start), shutdown: .async(item.shutdown))

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown { error in
                guard let shutdownError = error as? ShutdownError else {
                    return XCTFail("expected error to match")
                }
                XCTAssertEqual(shutdownError.errors.count, 1)
                XCTAssert(shutdownError.errors.values.first! is TestError, "expected error to match")
            }
        }

        XCTAssertFalse(item.shutdown, "expected item to be shutdown")
    }

    func testStatefulNIO() {
        class Item {
            let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            let id: String = UUID().uuidString
            var shutdown: Bool = false

            func start() -> EventLoopFuture<String> {
                return self.eventLoopGroup.next().makeSucceededFuture(self.id)
            }

            func shutdown(state: String) -> EventLoopFuture<Void> {
                XCTAssertEqual(self.id, state)
                self.shutdown = true // not thread safe but okay for this purpose
                return self.eventLoopGroup.next().makeSucceededFuture(())
            }
        }

        let lifecycle = ComponentLifecycle(label: "test")

        let item = Item()
        lifecycle.registerStateful(label: "test", start: .eventLoopFuture(item.start), shutdown: .eventLoopFuture(item.shutdown))

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertTrue(item.shutdown, "expected item to be shutdown")
    }

    func testStatefulNIOStartFailure() {
        class Item {
            let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            let id: String = UUID().uuidString

            func start() -> EventLoopFuture<String> {
                return self.eventLoopGroup.next().makeFailedFuture(TestError())
            }

            func shutdown(state: String) -> EventLoopFuture<Void> {
                XCTFail("should not be shutdown")
                return self.eventLoopGroup.next().makeFailedFuture(TestError())
            }
        }

        let lifecycle = ComponentLifecycle(label: "test")

        let item = Item()
        lifecycle.registerStateful(label: "test", start: .eventLoopFuture(item.start), shutdown: .eventLoopFuture(item.shutdown))

        XCTAssertThrowsError(try lifecycle.startAndWait()) { error in
            XCTAssert(error is TestError, "expected error to match")
        }
    }

    func testStatefulNIOShutdownFailure() {
        class Item {
            let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            let id: String = UUID().uuidString
            var shutdown: Bool = false

            func start() -> EventLoopFuture<String> {
                return self.eventLoopGroup.next().makeSucceededFuture(self.id)
            }

            func shutdown(state: String) -> EventLoopFuture<Void> {
                XCTAssertEqual(self.id, state)
                return self.eventLoopGroup.next().makeFailedFuture(TestError())
            }
        }

        let lifecycle = ComponentLifecycle(label: "test")

        let item = Item()
        lifecycle.registerStateful(label: "test", start: .eventLoopFuture(item.start), shutdown: .eventLoopFuture(item.shutdown))

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown { error in
                guard let shutdownError = error as? ShutdownError else {
                    return XCTFail("expected error to match")
                }
                XCTAssertEqual(shutdownError.errors.count, 1)
                XCTAssert(shutdownError.errors.values.first! is TestError, "expected error to match")
            }
        }

        XCTAssertFalse(item.shutdown, "expected item to be shutdown")
    }
}
