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

import Lifecycle
import NIO

extension LifecycleHandler {
    /// Asynchronous `LifecycleHandler` based on an `EventLoopFuture`.
    ///
    /// - parameters:
    ///    - future: function returning the underlying `EventLoopFuture`
    public static func eventLoopFuture(_ future: @escaping () -> EventLoopFuture<Void>) -> LifecycleHandler {
        return LifecycleHandler { callback in
            future().whenComplete { result in
                switch result {
                case .success:
                    callback(nil)
                case .failure(let error):
                    callback(error)
                }
            }
        }
    }
}

extension LifecycleHandler {
    /// `LifecycleHandler` that cancels a `RepeatedTask`.
    ///
    /// - parameters:
    ///    - task: `RepeatedTask` to be cancelled
    ///    - on: `EventLoop` to use for cancelling the task
    public static func cancelRepeatedTask(_ task: RepeatedTask, on eventLoop: EventLoop) -> LifecycleHandler {
        return self.eventLoopFuture {
            let promise = eventLoop.makePromise(of: Void.self)
            task.cancel(promise: promise)
            return promise.futureResult
        }
    }
}

extension LifecycleStartHandler {
    /// Asynchronous `LifecycleStartHandler` based on an `EventLoopFuture`.
    ///
    /// - parameters:
    ///    - future: function returning the underlying `EventLoopFuture`
    public static func eventLoopFuture(_ future: @escaping () -> EventLoopFuture<State>) -> LifecycleStartHandler {
        return LifecycleStartHandler { callback in
            future().whenComplete { result in
                callback(result)
            }
        }
    }
}

extension LifecycleShutdownHandler {
    /// Asynchronous `LifecycleShutdownHandler` based on an `EventLoopFuture`.
    ///
    /// - parameters:
    ///    - future: function returning the underlying `EventLoopFuture`
    public static func eventLoopFuture(_ future: @escaping (State) -> EventLoopFuture<Void>) -> LifecycleShutdownHandler {
        return LifecycleShutdownHandler { state, callback in
            future(state).whenComplete { result in
                switch result {
                case .success:
                    callback(nil)
                case .failure(let error):
                    callback(error)
                }
            }
        }
    }
}

extension ComponentLifecycle {
    /// Starts the provided `LifecycleItem` array.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - eventLoop: The `eventLoop` which is used to generate the `EventLoopFuture` that is returned. After the start the future is fulfilled:
    public func start(on eventLoop: EventLoop) -> EventLoopFuture<Void> {
        let promise = eventLoop.makePromise(of: Void.self)
        self.start { error in
            if let error = error {
                promise.fail(error)
            } else {
                promise.succeed(())
            }
        }
        return promise.futureResult
    }
}
