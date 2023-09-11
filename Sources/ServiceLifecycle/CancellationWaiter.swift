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
    private var taskContinuation: CheckedContinuation<Void, Error>?

    @usableFromInline
    init() {}

    @usableFromInline
    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withGracefulShutdownHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.taskContinuation = continuation
                }
            } onGracefulShutdown: {
                Task {
                    await self.finish()
                }
            }
        } onCancel: {
            Task {
                await self.finish(throwing: CancellationError())
            }
        }
    }

    private func finish(throwing error: Error? = nil) {
        if let error {
            self.taskContinuation?.resume(throwing: error)
        } else {
            self.taskContinuation?.resume()
        }
        self.taskContinuation = nil
    }
}
