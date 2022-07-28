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

import Foundation
import Lifecycle
import NIO
import NIOConcurrencyHelpers

class GoodItem: LifecycleTask {
    let queue = DispatchQueue(label: "GoodItem", attributes: .concurrent)

    let id: String
    let startDelay: Double
    let shutdownDelay: Double

    var state = State.idle
    let stateLock = Lock()

    init(id: String = UUID().uuidString,
         startDelay: Double = Double.random(in: 0.01 ... 0.1),
         shutdownDelay: Double = Double.random(in: 0.01 ... 0.1)) {
        self.id = id
        self.startDelay = startDelay
        self.shutdownDelay = shutdownDelay
    }

    var label: String {
        return self.id
    }

    func start(_ callback: @escaping (Error?) -> Void) {
        self.queue.asyncAfter(deadline: .now() + self.startDelay) {
            self.stateLock.withLock { self.state = .started }
            callback(nil)
        }
    }

    func shutdown(_ callback: @escaping (Error?) -> Void) {
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

class NIOItem {
    let id: String
    let eventLoopGroup: EventLoopGroup
    let startDelay: Int64
    let shutdownDelay: Int64

    var state = State.idle
    let stateLock = Lock()

    init(eventLoopGroup: EventLoopGroup,
         id: String = UUID().uuidString,
         startDelay: Int64 = Int64.random(in: 10 ... 20),
         shutdownDelay: Int64 = Int64.random(in: 10 ... 20)) {
        self.id = id
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

struct TestError: Error {}
