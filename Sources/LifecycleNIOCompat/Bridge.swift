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

import Lifecycle
import NIO

extension Lifecycle {
    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - name: name of the item, useful for debugging.
    ///    - start: closure to perform the startup.
    ///    - shutdown: closure to perform the shutdown.
    public func register(name: String, start: @escaping () -> EventLoopFuture<Void>, shutdown: @escaping () -> EventLoopFuture<Void>) {
        self.register(name: name, start: .async(start), shutdown: .async(shutdown))
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - name: name of the item, useful for debugging.
    ///    - start: closure to perform the startup.
    ///    - shutdown: closure to perform the shutdown.
    public func registerShutdown(name: String, _ handler: @escaping () -> EventLoopFuture<Void>) {
        self.register(name: name, start: .none, shutdown: .async(handler))
    }
}

extension Lifecycle.Handler {
    /// Asynchronous `Lifecycle.Handler` based on an `EventLoopFuture`.
    ///
    /// - parameters:
    ///    - future: the underlying `EventLoopFuture`
    public static func async(_ future: @escaping () -> EventLoopFuture<Void>) -> Lifecycle.Handler {
        return Lifecycle.Handler { callback in
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
