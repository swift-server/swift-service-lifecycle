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
    /// Asynchronous `Lifecycle.Handler` based on an `EventLoopFuture`.
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
