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

/// A simple actor that provides a method that suspends forever until cancelled.
actor CancellableContinuation {
    /// The continuation.
    private var continuation: CheckedContinuation<Void, Never>?

    /// This method suspends forever until it is cancelled.
    func run() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task {
                await self.runCancelled()
            }
        }
    }

    private func runCancelled() {
        // This force unwrap is okay. We must have stored the continuation before we get into here.
        self.continuation!.resume()
    }
}
