//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftServiceLifecycle open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftServiceLifecycle project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftServiceLifecycle project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// An actor that provides a function to wait on cancellation/graceful shutdown.
@usableFromInline
actor CancellationWaiter {
    @usableFromInline
    enum Reason {
        case cancelled
        case gracefulShutdown
    }

    private var taskContinuation: CheckedContinuation<Reason, Never>?

    @usableFromInline
    init() {}

    @usableFromInline
    func wait() async -> Reason {
        await withTaskCancellationHandler {
            await withGracefulShutdownHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Reason, Never>) in
                    self.taskContinuation = continuation
                }
            } onGracefulShutdown: {
                Task {
                    await self.finish(reason: .gracefulShutdown)
                }
            }
        } onCancel: {
            Task {
                await self.finish(reason: .cancelled)
            }
        }
    }

    private func finish(reason: Reason) {
        self.taskContinuation?.resume(returning: reason)
        self.taskContinuation = nil
    }
}
