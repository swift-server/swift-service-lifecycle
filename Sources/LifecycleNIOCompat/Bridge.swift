//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftServiceBootstrap open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the SwiftServiceBootstrap project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftServiceBootstrap project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Lifecycle
import NIO

extension Lifecycle.Handler {
    /// Asynchronous `Lifecycle.Handler` based on an `EventLoopFuture`.
    ///
    /// - parameters:
    ///    - future: function returning the underlying `EventLoopFuture`
    public static func eventLoopFuture(_ future: @escaping () -> EventLoopFuture<Void>) -> Lifecycle.Handler {
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
