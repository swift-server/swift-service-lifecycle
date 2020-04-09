//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftServiceLauncher open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the SwiftServiceLauncher project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftServiceLauncher project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
@testable import ServiceLauncher
import ServiceLauncherNIOCompat
import XCTest

final class Tests: XCTestCase {
    func testStartThenShutdown() {
        let items = (5 ... Int.random(in: 10 ... 20)).map { _ in GoodItem() }
        let lifecycle = Lifecycle()
        lifecycle.register(items)
        lifecycle.start(configuration: .init(shutdownSignal: nil)) { startError in
            XCTAssertNil(startError, "not expecting error")
            lifecycle.shutdown { shutdownErrors in
                XCTAssertNil(shutdownErrors, "not expecting error")
            }
        }
        lifecycle.wait()
        items.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    // FIXME: this test does not work in rio
    func _testShutdownWithSignal() {
        let signal = Lifecycle.Signal.ALRM
        let items = (5 ... Int.random(in: 10 ... 20)).map { _ in GoodItem() }
        let lifecycle = Lifecycle()
        lifecycle.register(items)
        let configuration = Lifecycle.Configuration(shutdownSignal: [signal])
        lifecycle.start(configuration: configuration) { error in
            XCTAssertNil(error, "not expecting error")
            kill(getpid(), signal.rawValue)
        }
        lifecycle.wait()
        items.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testDefaultCallbackQueue() {
        let lifecycle = Lifecycle()
        var startCalls = [String]()
        var stopCalls = [String]()

        let items = (1 ... Int.random(in: 10 ... 20)).map { index -> LifecycleItem in
            let id = "item-\(index)"
            return Lifecycle.Item(label: id,
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

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { startError in
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
        let lifecycle = Lifecycle()
        let testQueue = DispatchQueue(label: UUID().uuidString)
        var startCalls = [String]()
        var stopCalls = [String]()

        let items = (1 ... Int.random(in: 10 ... 20)).map { index -> LifecycleItem in
            let id = "item-\(index)"
            return Lifecycle.Item(label: id,
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

        lifecycle.start(configuration: .init(callbackQueue: testQueue, shutdownSignal: nil)) { startError in
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
        class Item: LifecycleItem {
            let startedCallback: () -> Void
            var state = State.idle

            let label = UUID().uuidString

            init(_ startedCallback: @escaping () -> Void) {
                self.startedCallback = startedCallback
            }

            func start(callback: @escaping (Error?) -> Void) {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    self.state = .started
                    self.startedCallback()
                    callback(nil)
                }
            }

            func shutdown(callback: (Error?) -> Void) {
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
        let lifecycle = Lifecycle()
        lifecycle.register(items)
        lifecycle.start(configuration: .init(shutdownSignal: nil)) { _ in }
        startSempahore.wait()
        lifecycle.shutdown()
        lifecycle.wait()
        XCTAssertGreaterThan(started, 0, "expected some start")
        XCTAssertLessThan(started, items.count, "exppcts partial start")
        items.prefix(started).forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
        items.suffix(started + 1).forEach { XCTAssertEqual($0.state, .idle, "expected item to be idle, but \($0.state)") }
    }

    func testShutdownWhenIdle() {
        let lifecycle = Lifecycle()
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
        let lifecycle = Lifecycle()
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
        let lifecycle = Lifecycle()
        let blockStartSemaphore = DispatchSemaphore(value: 0)
        var startCalls = [String]()
        var stopCalls = [String]()

        do {
            let id = UUID().uuidString
            lifecycle.register(label: id,
                               start: {
                                   startCalls.append(id)
                                   blockStartSemaphore.wait()
                               },
                               shutdown: {
                                   XCTAssertTrue(startCalls.contains(id))
                                   stopCalls.append(id)
                                })
        }
        do {
            let id = UUID().uuidString
            lifecycle.register(label: id,
                               start: {
                                   startCalls.append(id)
                               },
                               shutdown: {
                                   XCTAssertTrue(startCalls.contains(id))
                                   stopCalls.append(id)
                                })
        }
        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error)
        }
        lifecycle.shutdown()
        blockStartSemaphore.signal()
        lifecycle.wait()
        XCTAssertEqual(startCalls.count, 1)
        XCTAssertEqual(stopCalls.count, 1)
    }

    func testShutdownErrors() {
        class BadItem: LifecycleItem {
            let label = UUID().uuidString

            func start(callback: (Error?) -> Void) {
                callback(nil)
            }

            func shutdown(callback: (Error?) -> Void) {
                callback(TestError())
            }
        }

        var shutdownErrors: [String: Error]?
        let shutdownSemaphore = DispatchSemaphore(value: 0)
        let items: [LifecycleItem] = [GoodItem(), BadItem(), BadItem(), GoodItem(), BadItem()]
        let lifecycle = Lifecycle()
        lifecycle.register(items)
        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown { errors in
                shutdownErrors = errors
                shutdownSemaphore.signal()
            }
        }
        lifecycle.wait()
        XCTAssertEqual(.success, shutdownSemaphore.wait(timeout: .now() + 1))

        let goodItems = items.compactMap { $0 as? GoodItem }
        goodItems.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
        let badItems = items.compactMap { $0 as? BadItem }
        XCTAssertEqual(shutdownErrors?.count, badItems.count, "expected shutdown errors")
        badItems.forEach { XCTAssert(shutdownErrors?[$0.label] is TestError, "expected error to match") }
    }

    func testStartupErrors() {
        class BadItem: LifecycleItem {
            let label: String = UUID().uuidString

            func start(callback: (Error?) -> Void) {
                callback(TestError())
            }

            func shutdown(callback: (Error?) -> Void) {
                callback(nil)
            }
        }

        let items: [LifecycleItem] = [GoodItem(), GoodItem(), BadItem(), GoodItem()]
        let lifecycle = Lifecycle()
        lifecycle.register(items)
        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssert(error is TestError, "expected error to match")
        }
        lifecycle.wait()
        let badItemIndex = items.firstIndex { $0 as? BadItem != nil }!
        items.prefix(badItemIndex).compactMap { $0 as? GoodItem }.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
        items.suffix(from: badItemIndex + 1).compactMap { $0 as? GoodItem }.forEach { XCTAssertEqual($0.state, .idle, "expected item to be idle, but \($0.state)") }
    }

    func testStartAndWait() {
        class Item: LifecycleItem {
            private let semaphore: DispatchSemaphore
            var state = State.idle

            init(_ semaphore: DispatchSemaphore) {
                self.semaphore = semaphore
            }

            let label: String = UUID().uuidString

            func start(callback: (Error?) -> Void) {
                self.state = .started
                self.semaphore.signal()
                callback(nil)
            }

            func shutdown(callback: (Error?) -> Void) {
                self.state = .shutdown
                callback(nil)
            }

            enum State {
                case idle
                case started
                case shutdown
            }
        }

        let lifecycle = Lifecycle()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue(label: "test").asyncAfter(deadline: .now() + 0.1) {
            semaphore.wait()
            lifecycle.shutdown()
        }
        let item = Item(semaphore)
        lifecycle.register(item)
        XCTAssertNoThrow(try lifecycle.startAndWait(configuration: .init(shutdownSignal: nil)))
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown")
    }

    func testBadStartAndWait() {
        class BadItem: LifecycleItem {
            let label: String = UUID().uuidString

            func start(callback: (Error?) -> Void) {
                callback(TestError())
            }

            func shutdown(callback: (Error?) -> Void) {
                callback(nil)
            }
        }

        let lifecycle = Lifecycle()
        lifecycle.register(GoodItem(), BadItem())
        XCTAssertThrowsError(try lifecycle.startAndWait(configuration: .init(shutdownSignal: nil))) { error in
            XCTAssert(error is TestError, "expected error to match")
        }
    }

    func testShutdownInOrder() {
        class Item: LifecycleItem {
            let id: String
            var result: [String]

            init(_ result: inout [String]) {
                self.id = UUID().uuidString
                self.result = result
            }

            var label: String {
                return self.id
            }

            func start(callback: (Error?) -> Void) {
                self.result.append(self.id)
                callback(nil)
            }

            func shutdown(callback: (Error?) -> Void) {
                if self.result.last == self.id {
                    _ = self.result.removeLast()
                }
                callback(nil)
            }
        }

        var result = [String]()
        let items = [Item(&result), Item(&result), Item(&result), Item(&result)]
        let lifecycle = Lifecycle()
        lifecycle.register(items)
        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
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

        let lifecycle = Lifecycle()
        let items = (5 ... Int.random(in: 10 ... 20)).map { _ in Sync() }
        items.forEach { item in
            lifecycle.register(label: item.id, start: item.start, shutdown: item.shutdown)
        }

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        items.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testAyncBarrier() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let lifecycle = Lifecycle()

        let item1 = NIOItem(eventLoopGroup: eventLoopGroup)
        lifecycle.register(label: "item1", start: .eventLoopFuture(item1.start), shutdown: .eventLoopFuture(item1.shutdown))

        lifecycle.register(label: "blocker",
                           start: { () -> Void in try eventLoopGroup.next().makeSucceededFuture(()).wait() },
                           shutdown: { () -> Void in try eventLoopGroup.next().makeSucceededFuture(()).wait() })

        let item2 = NIOItem(eventLoopGroup: eventLoopGroup)
        lifecycle.register(label: "item2", start: .eventLoopFuture(item2.start), shutdown: .eventLoopFuture(item2.shutdown))

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        [item1, item2].forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testConcurrency() {
        let lifecycle = Lifecycle()
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

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
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

        let lifecycle = Lifecycle()

        let item = Sync()
        lifecycle.register(label: "test",
                           start: item.start,
                           shutdown: item.shutdown)

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
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

        let lifecycle = Lifecycle()

        let item = Sync()
        lifecycle.registerShutdown(label: "test", item.shutdown)

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterAsync() {
        let lifecycle = Lifecycle()

        let item = GoodItem()
        lifecycle.register(label: "test",
                           start: .async(item.start),
                           shutdown: .async(item.shutdown))

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterShutdownAsync() {
        let lifecycle = Lifecycle()

        let item = GoodItem()
        lifecycle.registerShutdown(label: "test", .async(item.shutdown))

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterAsyncClosure() {
        let lifecycle = Lifecycle()

        let item = GoodItem()
        lifecycle.register(label: "test",
                           start: .async { callback in
                               item.start(callback: callback)
                           },
                           shutdown: .async { callback in
                               item.shutdown(callback: callback)
                           })

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterShutdownAsyncClosure() {
        let lifecycle = Lifecycle()

        let item = GoodItem()
        lifecycle.registerShutdown(label: "test", .async { callback in
            item.shutdown(callback: callback)
        })

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterNIO() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let lifecycle = Lifecycle()

        let item = NIOItem(eventLoopGroup: eventLoopGroup)
        lifecycle.register(label: item.id,
                           start: .eventLoopFuture(item.start),
                           shutdown: .eventLoopFuture(item.shutdown))

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterShutdownNIO() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let lifecycle = Lifecycle()

        let item = NIOItem(eventLoopGroup: eventLoopGroup)
        lifecycle.registerShutdown(label: item.id, .eventLoopFuture(item.shutdown))

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterNIOClosure() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let lifecycle = Lifecycle()

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

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterShutdownNIOClosure() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let lifecycle = Lifecycle()

        let item = NIOItem(eventLoopGroup: eventLoopGroup)
        lifecycle.registerShutdown(label: item.id, .eventLoopFuture {
            print("shutdown")
            return item.shutdown()
        })

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testNIOFailure() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let lifecycle = Lifecycle()

        lifecycle.register(label: "test",
                           start: .eventLoopFuture { eventLoopGroup.next().makeFailedFuture(TestError()) },
                           shutdown: .eventLoopFuture { eventLoopGroup.next().makeSucceededFuture(()) })

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
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
        let lifecycle = Lifecycle()
        lifecycle.register(label: "test",
                           start: .async(item.start),
                           shutdown: .async(item.shutdown))

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
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
        let lifecycle = Lifecycle()
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

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            XCTAssertEqual(state, .started(expectedData), "expected item to be shutdown, but \(state)")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(state, .shutdown, "expected item to be shutdown, but \(state)")
    }
}

private class GoodItem: LifecycleItem {
    let queue = DispatchQueue(label: "GoodItem", attributes: .concurrent)
    let startDelay: Double
    let shutdownDelay: Double

    var state = State.idle
    let stateLock = Lock()

    init(startDelay: Double = Double.random(in: 0.01 ... 0.1), shutdownDelay: Double = Double.random(in: 0.01 ... 0.1)) {
        self.startDelay = startDelay
        self.shutdownDelay = shutdownDelay
    }

    let label: String = UUID().uuidString

    func start(callback: @escaping (Error?) -> Void) {
        self.queue.asyncAfter(deadline: .now() + self.startDelay) {
            self.stateLock.withLock { self.state = .started }
            callback(nil)
        }
    }

    func shutdown(callback: @escaping (Error?) -> Void) {
        self.queue.asyncAfter(deadline: .now() + self.shutdownDelay) {
            self.stateLock.withLock { self.state = .shutdown }
            callback(nil)
        }
    }

    enum State {
        case idle
        case started
        case shutdown
    }
}

private class NIOItem {
    let id: String
    let eventLoopGroup: EventLoopGroup
    let startDelay: Int64
    let shutdownDelay: Int64

    var state = State.idle
    let stateLock = Lock()

    init(eventLoopGroup: EventLoopGroup, startDelay: Int64 = Int64.random(in: 10 ... 20), shutdownDelay: Int64 = Int64.random(in: 10 ... 20)) {
        self.id = UUID().uuidString
        self.eventLoopGroup = eventLoopGroup
        self.startDelay = startDelay
        self.shutdownDelay = shutdownDelay
    }

    func start() -> EventLoopFuture<Void> {
        return self.eventLoopGroup.next().scheduleTask(in: .milliseconds(self.startDelay)) {
            self.stateLock.withLock { self.state = .started }
        }.futureResult
    }

    func shutdown() -> EventLoopFuture<Void> {
        return self.eventLoopGroup.next().scheduleTask(in: .milliseconds(self.shutdownDelay)) {
            self.stateLock.withLock { self.state = .shutdown }
        }.futureResult
    }

    enum State {
        case idle
        case started
        case shutdown
    }
}

private struct TestError: Error {}
