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
import LifecycleCommand
import XCTest

final class LifecycleCommandTests: XCTestCase {
    func testStartsRegisteredServices() throws {
        let command = TestCommand()

        DispatchQueue(label: "test").asyncAfter(deadline: .now() + 0.1) {
            kill(getpid(), ServiceLifecycle.Signal.ALRM.rawValue)
        }

        try command.run()

        XCTAssertTrue(command.bootstrapCalled)
        XCTAssertTrue(command.taskStarted)
        XCTAssertTrue(command.taskStopped)
    }
}

private final class TestCommand: ServiceCommand {
    private(set) var bootstrapCalled = false
    private(set) var taskStarted = false
    private(set) var taskStopped = false

    static var lifecycle = ServiceLifecycle(configuration: .init(shutdownSignal: [ServiceLifecycle.Signal.ALRM]))

    func bootstrap() throws {
        self.bootstrapCalled = true
    }

    func configure(_ lifecycle: ServiceLifecycle) throws {
        lifecycle.register(
            label: "test",
            start: .sync {
                self.taskStarted = true
            },
            shutdown: .sync {
                self.taskStopped = true
            }
        )
    }
}
