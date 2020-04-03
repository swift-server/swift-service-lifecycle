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

final class LifeycleTests: XCTestCase {
    func testStartThenShutdown() {
        let items = (0 ... Int.random(in: 10 ... 20)).map { _ in GoodItem() }
        let lifecycle = Lifecycle(label: "test")
        lifecycle.register(items)
        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            items.forEach { XCTAssertEqual($0.state, .started, "expected item to be started, but \($0.state)") }
            lifecycle.shutdown()
        }
        lifecycle.wait()
        items.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testImmediateShutdown() {
        let items = (0 ... Int.random(in: 10 ... 20)).map { _ in GoodItem() }
        let lifecycle = Lifecycle(label: "test")
        lifecycle.register(items)
        lifecycle.start { _ in }
        lifecycle.shutdown()
        lifecycle.wait()
        items.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testBadStartup() {
        class BadItem: LifecycleItem {
            let label: String = UUID().uuidString

            func start(callback: (Error?) -> Void) {
                callback(TestError())
            }

            func shutdown(callback: (Error?) -> Void) {
                callback(nil)
            }
        }

        let items: [LifecycleItem] = [GoodItem(), BadItem(), GoodItem()]
        let lifecycle = Lifecycle(label: "test")
        lifecycle.register(items)
        lifecycle.start { error in
            XCTAssert(error is TestError, "expected error to match")
        }
        lifecycle.wait()
        let goodItems = items.compactMap { $0 as? GoodItem }
        goodItems.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testBadShutdown() {
        class BadItem: LifecycleItem {
            let label = UUID().uuidString

            func start(callback: (Error?) -> Void) {
                callback(nil)
            }

            func shutdown(callback: (Error?) -> Void) {
                callback(TestError())
            }
        }

        var shutdownError: Lifecycle.ShutdownError?
        let items: [LifecycleItem] = [GoodItem(), BadItem(), BadItem(), GoodItem(), BadItem()]
        let lifecycle = Lifecycle(label: "test")
        lifecycle.register(items)
        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown { error in
                shutdownError = error as? Lifecycle.ShutdownError
            }
        }
        lifecycle.wait()

        let goodItems = items.compactMap { $0 as? GoodItem }
        goodItems.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
        let badItems = items.compactMap { $0 as? BadItem }
        XCTAssertEqual(shutdownError?.errors.count, badItems.count, "expected shutdown errors")
        badItems.forEach { XCTAssert(shutdownError!.errors[$0.label] is TestError, "expected error to match") }
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
        let lifecycle = Lifecycle(label: "test")
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

        let lifecycle = Lifecycle(label: "test")
        let items = (0 ... Int.random(in: 10 ... 20)).map { _ in Sync() }
        items.forEach { item in
            lifecycle.register(label: item.id, start: item.start, shutdown: item.shutdown)
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
        let lifecycle = Lifecycle(label: "test")

        let item1 = NIOItem(eventLoopGroup: eventLoopGroup)
        lifecycle.register(label: "item1", start: .eventLoopFuture(item1.start), shutdown: .eventLoopFuture(item1.shutdown))

        lifecycle.register(label: "blocker",
                           start: { () -> Void in try eventLoopGroup.next().makeSucceededFuture(()).wait() },
                           shutdown: { () -> Void in try eventLoopGroup.next().makeSucceededFuture(()).wait() })

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
        let lifecycle = Lifecycle(label: "test")
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

        let lifecycle = Lifecycle(label: "test")

        let item = Sync()
        lifecycle.register(label: "test",
                           start: item.start,
                           shutdown: item.shutdown)

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

        let lifecycle = Lifecycle(label: "test")

        let item = Sync()
        lifecycle.registerShutdown(label: "test", item.shutdown)

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterAsync() {
        let lifecycle = Lifecycle(label: "test")

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
        let lifecycle = Lifecycle(label: "test")

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
        let lifecycle = Lifecycle(label: "test")

        let item = GoodItem()
        lifecycle.register(label: "test",
                           start: .async { callback in
                               print("start")
                               item.start(callback: callback)
                           },
                           shutdown: .async { callback in
                               print("shutdown")
                               item.shutdown(callback: callback)
                           })

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            lifecycle.shutdown()
        }
        lifecycle.wait()
        XCTAssertEqual(item.state, .shutdown, "expected item to be shutdown, but \(item.state)")
    }

    func testRegisterShutdownAsyncClosure() {
        let lifecycle = Lifecycle(label: "test")

        let item = GoodItem()
        lifecycle.registerShutdown(label: "test", .async { callback in
            print("shutdown")
            item.shutdown(callback: callback)
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
        let lifecycle = Lifecycle(label: "test")

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
        let lifecycle = Lifecycle(label: "test")

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
        let lifecycle = Lifecycle(label: "test")

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
        let lifecycle = Lifecycle(label: "test")

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
        let lifecycle = Lifecycle(label: "test")

        lifecycle.register(label: "test",
                           start: .eventLoopFuture { eventLoopGroup.next().makeFailedFuture(TestError()) },
                           shutdown: .eventLoopFuture { eventLoopGroup.next().makeSucceededFuture(()) })

        lifecycle.start { error in
            XCTAssert(error is TestError, "expected error to match")
            lifecycle.shutdown()
        }
        lifecycle.wait()
    }

    func testExternalState() {
        enum State: Equatable {
            case idle
            case started(String)
            case shutdown
        }

        class Item {
            let eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

            let data: String
            init(_ data: String) {
                self.data = data
            }

            func start() -> EventLoopFuture<String> {
                return self.eventLoopGroup.next().makeSucceededFuture(self.data)
            }

            func shutdown() -> EventLoopFuture<Void> {
                return self.eventLoopGroup.next().makeSucceededFuture(())
            }
        }

        var state = State.idle

        let expectedData = UUID().uuidString
        let item = Item(expectedData)
        let lifecycle = Lifecycle(label: "test")
        lifecycle.register(label: "test",
                           start: .eventLoopFuture {
                               item.start().map { data -> Void in
                                   state = .started(data)
                               }
                           },
                           shutdown: .eventLoopFuture {
                               item.shutdown().map { _ -> Void in
                                   state = .shutdown
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
