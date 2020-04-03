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

@testable import ServiceLauncher
import ServiceLauncherNIOCompat
import XCTest

final class TopLevelTests: XCTestCase {
    func testShutdownWithSignal() {
        let signal = TopLevelLifecycle.Signal.ALRM
        let items = (0 ... Int.random(in: 10 ... 20)).map { _ in GoodItem() }
        let lifecycle = TopLevelLifecycle()
        lifecycle.register(items)
        lifecycle.start(configuration: .init(shutdownSignal: [signal])) { error in
            XCTAssertNil(error, "not expecting error")
            kill(getpid(), signal.rawValue)
        }
        lifecycle.wait()
        items.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testStartAndWait() {
        class Item: LifecycleItem {
            private let semaphore: DispatchSemaphore
            var state = State.idle

            init(_ semaphore: DispatchSemaphore) {
                self.semaphore = semaphore
            }

            var label: String {
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

        let lifecycle = TopLevelLifecycle()
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
            var label: String {
                return "\(self)"
            }

            func start(callback: (Error?) -> Void) {
                callback(TestError())
            }

            func shutdown(callback: (Error?) -> Void) {
                callback(nil)
            }
        }

        let lifecycle = TopLevelLifecycle()
        lifecycle.register(GoodItem(), BadItem())
        XCTAssertThrowsError(try lifecycle.startAndWait(configuration: .init(shutdownSignal: nil))) { error in
            XCTAssert(error is TestError, "expected error to match")
        }
    }

    func testNesting() {
        let items1 = (0 ... Int.random(in: 10 ... 20)).map { _ in GoodItem() }
        let lifecycle1 = Lifecycle(label: "test1")
        lifecycle1.register(items1)

        let items2 = (0 ... Int.random(in: 10 ... 20)).map { _ in GoodItem() }
        let lifecycle2 = Lifecycle(label: "test2")
        lifecycle2.register(items2)

        let lifecycle = TopLevelLifecycle()
        let items3 = (0 ... Int.random(in: 10 ... 20)).map { _ in GoodItem() }
        lifecycle.register([lifecycle1, lifecycle2] + items3)

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            items1.forEach { XCTAssertEqual($0.state, .started, "expected item to be started, but \($0.state)") }
            items2.forEach { XCTAssertEqual($0.state, .started, "expected item to be started, but \($0.state)") }
            items3.forEach { XCTAssertEqual($0.state, .started, "expected item to be started, but \($0.state)") }
            lifecycle.shutdown()
        }
        lifecycle.wait()
        items1.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
        items2.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
        items3.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
    }
}
