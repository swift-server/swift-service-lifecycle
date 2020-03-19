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

@testable import Lifecycle
import LifecycleNIOCompat
import NIO
import NIOConcurrencyHelpers
import XCTest

final class Tests: XCTestCase {
    func testStartThenShutdown() {
        let items = (0 ... Int.random(in: 10 ... 20)).map { _ in GoodItem() }
        let lifecycle = Lifecycle()
        lifecycle.register(items)
        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        items.forEach { XCTAssert($0.state == .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    // FIXME: this test does not work in rio
    func _testShutdownWithSignal() {
        let signal = Lifecycle.Signal.ALRM
        let items = (0 ... Int.random(in: 10 ... 20)).map { _ in GoodItem() }
        let lifecycle = Lifecycle()
        lifecycle.register(items)
        let configuration = Lifecycle.Configuration(shutdownSignal: [signal])
        lifecycle.start(configuration: configuration) { error in
            XCTAssertNil(error, "not expecting error")
            kill(getpid(), signal.rawValue)
        }
        lifecycle.wait()
        items.forEach { XCTAssert($0.state == .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testImmediateShutdown() {
        let items = (0 ... Int.random(in: 10 ... 20)).map { _ in GoodItem() }
        let lifecycle = Lifecycle()
        lifecycle.register(items)
        lifecycle.start(configuration: .init(shutdownSignal: nil)) { _ in }
        lifecycle.shutdown()
        lifecycle.wait()
        items.forEach { XCTAssert($0.state == .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testBadStartup() {
        class BadItem: LifecycleItem {
            var name: String {
                return "\(self)"
            }

            func start(callback: (Error?) -> Void) {
                callback(TestError())
            }

            func shutdown(callback: (Error?) -> Void) {
                callback(nil)
            }
        }

        let items: [LifecycleItem] = [GoodItem(), BadItem(), GoodItem()]
        let lifecycle = Lifecycle()
        lifecycle.register(items)
        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssert(error is TestError, "expected error to match")
        }
        lifecycle.wait()
        let goodItems = items.compactMap { $0 as? GoodItem }
        goodItems.forEach { XCTAssert($0.state == .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testBadShutdown() {
        class BadItem: LifecycleItem {
            var name: String {
                return "\(self)"
            }

            func start(callback: (Error?) -> Void) {
                callback(nil)
            }

            func shutdown(callback: (Error?) -> Void) {
                callback(TestError())
            }
        }

        let items: [LifecycleItem] = [GoodItem(), BadItem(), GoodItem()]
        let lifecycle = Lifecycle()
        lifecycle.register(items)
        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        items.compactMap { $0 as? GoodItem }.forEach { XCTAssert($0.state == .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testStartAndWait() {
        class Item: LifecycleItem {
            private let semaphore: DispatchSemaphore
            var state = State.idle

            init(_ semaphore: DispatchSemaphore) {
                self.semaphore = semaphore
            }

            var name: String {
                return "\(self)"
            }

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
            var name: String {
                return "\(self)"
            }

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

            var name: String {
                return "\(self.id)"
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
        let items = (0 ... Int.random(in: 10 ... 20)).map { _ in Sync() }
        items.forEach { item in
            lifecycle.register(name: item.id, start: item.start, shutdown: item.shutdown)
        }

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        items.forEach { XCTAssert($0.state == .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testAyncBarrier() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let lifecycle = Lifecycle()

        let item1 = NIOItem(eventLoopGroup: eventLoopGroup)
        lifecycle.register(name: "item1", start: item1.start, shutdown: item1.shutdown)

        lifecycle.register(name: "blocker",
                           start: { () -> Void in try eventLoopGroup.next().makeSucceededFuture(()).wait() },
                           shutdown: { () -> Void in try eventLoopGroup.next().makeSucceededFuture(()).wait() })

        let item2 = NIOItem(eventLoopGroup: eventLoopGroup)
        lifecycle.register(name: "item2", start: item2.start, shutdown: item2.shutdown)

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        [item1, item2].forEach { XCTAssert($0.state == .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testConcurrncy() {
        let lifecycle = Lifecycle()
        let items = (0 ... 50000).map { _ in GoodItem(startDelay: 0, shutdownDelay: 0) }
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
        items.forEach { XCTAssert($0.state == .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testRegisterAsync() {
        let lifecycle = Lifecycle()

        let item = GoodItem()
        lifecycle.register(name: "test",
                           start: item.start,
                           shutdown: item.shutdown)

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssert(item.state == .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterAsyncClosure() {
        let lifecycle = Lifecycle()

        let item = GoodItem()
        lifecycle.register(name: "test",
                           start: .async { callback in
                               print("start")
                               item.start(callback: callback)
                           },
                           shutdown: .async { callback in
                               print("shutdown")
                               item.shutdown(callback: callback)
                           })

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssert(item.state == .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterShutdownAsync() {
        let lifecycle = Lifecycle()

        let item = GoodItem()
        lifecycle.registerShutdown(name: "test", item.shutdown)

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssert(item.state == .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterShutdownAsyncClosure() {
        let lifecycle = Lifecycle()

        let item = GoodItem()
        lifecycle.registerShutdown(name: "test", .async { callback in
            print("shutdown")
            item.shutdown(callback: callback)
        })

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssert(item.state == .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterNIO() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let lifecycle = Lifecycle()

        let item = NIOItem(eventLoopGroup: eventLoopGroup)
        lifecycle.register(name: item.id,
                           start: item.start,
                           shutdown: item.shutdown)

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssert(item.state == .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterNIOClosure() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let lifecycle = Lifecycle()

        let item = NIOItem(eventLoopGroup: eventLoopGroup)
        lifecycle.register(name: item.id,
                           start: .async {
                               print("start")
                               return item.start()
                           },
                           shutdown: .async {
                               print("shutdown")
                               return item.shutdown()
                           })

        lifecycle.start(configuration: .init(shutdownSignal: nil)) { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssert(item.state == .shutdown, "expected item to be shutdown, but \(item.state)")
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

    var name: String {
        return "\(GoodItem.self)"
    }

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
