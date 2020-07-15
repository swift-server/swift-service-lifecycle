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
import XCTest

final class ServiceLifecycleTests: XCTestCase {
    func testStartThenShutdown() {
        let items = (5 ... Int.random(in: 10 ... 20)).map { _ in GoodItem() }
        let lifecycle = ServiceLifecycle(configuration: .init(shutdownSignal: nil))
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

    func testShutdownWithSignal() {
        if ProcessInfo.processInfo.environment["SKIP_SIGNAL_TEST"].flatMap(Bool.init) ?? false {
            print("skipping testShutdownWithSignal")
            return
        }
        let signal = ServiceLifecycle.Signal.ALRM
        let items = (0 ... Int.random(in: 10 ... 20)).map { _ in GoodItem() }
        let lifecycle = ServiceLifecycle(configuration: .init(shutdownSignal: [signal]))
        lifecycle.register(items)
        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            kill(getpid(), signal.rawValue)
        }
        lifecycle.wait()
        items.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testStartAndWait() {
        class Item: LifecycleTask {
            private let semaphore: DispatchSemaphore
            var state = State.idle

            init(_ semaphore: DispatchSemaphore) {
                self.semaphore = semaphore
            }

            var label: String {
                return "\(self)"
            }

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

        let lifecycle = ServiceLifecycle(configuration: .init(shutdownSignal: nil))
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
            var label: String {
                return "\(self)"
            }

            func start(_ callback: (Error?) -> Void) {
                callback(TestError())
            }

            func shutdown(_ callback: (Error?) -> Void) {
                callback(nil)
            }
        }

        let lifecycle = ServiceLifecycle(configuration: .init(shutdownSignal: nil))
        lifecycle.register(GoodItem(), BadItem())
        XCTAssertThrowsError(try lifecycle.startAndWait()) { error in
            XCTAssert(error is TestError, "expected error to match")
        }
    }

    func testNesting() {
        let items1 = (0 ... Int.random(in: 10 ... 20)).map { _ in GoodItem() }
        let subLifecycle1 = ComponentLifecycle(label: "sub1")
        subLifecycle1.register(items1)

        let items2 = (0 ... Int.random(in: 10 ... 20)).map { _ in GoodItem() }
        let subLifecycle2 = ComponentLifecycle(label: "sub2")
        subLifecycle2.register(items2)

        let toplifecycle = ServiceLifecycle()
        let items3 = (0 ... Int.random(in: 10 ... 20)).map { _ in GoodItem() }
        toplifecycle.register([subLifecycle1, subLifecycle2] + items3)

        toplifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            items1.forEach { XCTAssertEqual($0.state, .started, "expected item to be started, but \($0.state)") }
            items2.forEach { XCTAssertEqual($0.state, .started, "expected item to be started, but \($0.state)") }
            items3.forEach { XCTAssertEqual($0.state, .started, "expected item to be started, but \($0.state)") }
            toplifecycle.shutdown()
        }
        toplifecycle.wait()
        items1.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
        items2.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
        items3.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testNesting2() {
        struct SubSystem {
            let lifecycle = ComponentLifecycle(label: "SubSystem")
            let subsystem: SubSubSystem

            init() {
                self.subsystem = SubSubSystem()
                self.lifecycle.register(self.subsystem.lifecycle)
            }

            struct SubSubSystem {
                let lifecycle = ComponentLifecycle(label: "SubSubSystem")
                let items = (0 ... Int.random(in: 10 ... 20)).map { _ in GoodItem() }

                init() {
                    self.lifecycle.register(self.items)
                }
            }
        }

        let lifecycle = ServiceLifecycle()
        let subsystem = SubSystem()
        lifecycle.register(subsystem.lifecycle)

        lifecycle.start { error in
            XCTAssertNil(error, "not expecting error")
            subsystem.subsystem.items.forEach { XCTAssertEqual($0.state, .started, "expected item to be started, but \($0.state)") }
            lifecycle.shutdown()
        }
        lifecycle.wait()
        subsystem.subsystem.items.forEach { XCTAssertEqual($0.state, .shutdown, "expected item to be shutdown, but \($0.state)") }
    }

    func testSignalDescription() {
        XCTAssertEqual("\(ServiceLifecycle.Signal.TERM)", "Signal(TERM, rawValue: \(ServiceLifecycle.Signal.TERM.rawValue))")
        XCTAssertEqual("\(ServiceLifecycle.Signal.INT)", "Signal(INT, rawValue: \(ServiceLifecycle.Signal.INT.rawValue))")
        XCTAssertEqual("\(ServiceLifecycle.Signal.ALRM)", "Signal(ALRM, rawValue: \(ServiceLifecycle.Signal.ALRM.rawValue))")
    }
}
