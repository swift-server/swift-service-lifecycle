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

import ConcurrencyHelpers

/// Execute an operation with a graceful shutdown handler that’s immediately invoked if the current task is shutting down gracefully.
///
/// This doesn’t check for graceful shutdown, and always executes the passed operation.
/// The operation executes on the calling execution context and does not suspend by itself, unless the code contained within the closure does.
/// If graceful shutdown occurs while the operation is running, the graceful shutdown handler will execute concurrently with the operation.
///
/// When `withGracefulShutdownHandler` is used in a Task that has already been gracefully shutdown, the `onGracefulShutdown` handler
/// will be executed immediately before operation gets to execute. This allows the `onGracefulShutdown` handler to set some external “shutdown” flag
/// that the operation may be atomically checking for in order to avoid performing any actual work once the operation gets to run.
///
/// A common use-case is to listen to graceful shutdown and use the `ServerQuiescingHelper` from `swift-nio-extras` to
/// trigger the quiescing sequence. Furthermore, graceful shutdown will propagate to any child task that is currently executing
///
/// - Important: This method will only set up a handler if run inside ``ServiceGroup`` otherwise no graceful shutdown handler
/// will be set up.
///
/// - Parameters:
///   - operation: The actual operation.
///   - handler: The handler which is invoked once graceful shutdown has been triggered.
// Unsafely inheriting the executor is safe to do here since we are not calling any other async method
// except the operation. This makes sure no other executor hops would occur here.
@_unsafeInheritExecutor
public func withGracefulShutdownHandler<T>(
    operation: () async throws -> T,
    onGracefulShutdown handler: @Sendable @escaping () -> Void
) async rethrows -> T {
    guard let gracefulShutdownManager = TaskLocals.gracefulShutdownManager else {
        return try await operation()
    }

    // We have to keep track of our handler here to remove it once the operation is finished.
    let handlerID = gracefulShutdownManager.registerHandler(handler)
    defer {
        if let handlerID = handlerID {
            gracefulShutdownManager.removeHandler(handlerID)
        }
    }

    return try await operation()
}

/// Waits until graceful shutdown is triggered.
///
/// This method suspends the caller until graceful shutdown is triggered. If the calling task is cancelled before
/// graceful shutdown is triggered then this method will throw a `CancellationError`.
///
/// - Throws: `CancellationError` if the task is cancelled.
public func gracefulShutdown() async throws {
    try await AsyncGracefulShutdownSequence().first { _ in true }
}

/// This is just a helper type for the result of our task group.
enum ValueOrGracefulShutdown<T: Sendable>: Sendable {
    case value(T)
    case gracefulShutdown
}

/// Cancels the closure when a graceful shutdown was triggered.
///
/// - Parameter operation: The actual operation.
public func cancelOnGracefulShutdown<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) async rethrows -> T? {
    return try await withThrowingTaskGroup(of: ValueOrGracefulShutdown<T>.self) { group in
        group.addTask {
            let value = try await operation()
            return .value(value)
        }

        group.addTask {
            for try await _ in AsyncGracefulShutdownSequence() {
                return .gracefulShutdown
            }

            throw CancellationError()
        }

        let result = try await group.next()
        group.cancelAll()

        switch result {
        case .value(let t):
            return t
        case .gracefulShutdown:
            switch try await group.next() {
            case .value(let t):
                return t
            case .gracefulShutdown:
                fatalError("Unexpectedly got gracefulShutdown from group.next()")

            case nil:
                fatalError("Unexpectedly got nil from group.next()")
            }

        case nil:
            fatalError("Unexpectedly got nil from group.next()")
        }
    }
}

extension Task where Success == Never, Failure == Never {
    /// A Boolean value that indicates whether the task is gracefully shutting down
    ///
    /// After the value of this property becomes `true`, it remains `true` indefinitely. There is no way to undo a graceful shutdown.
    public static var isShuttingDownGracefully: Bool {
        guard let gracefulShutdownManager = TaskLocals.gracefulShutdownManager else {
            return false
        }

        return gracefulShutdownManager.isShuttingDown
    }
}

@_spi(TestKit)
public enum TaskLocals {
    @TaskLocal
    @_spi(TestKit)
    public static var gracefulShutdownManager: GracefulShutdownManager?
}

@_spi(TestKit)
public final class GracefulShutdownManager: @unchecked Sendable {
    struct Handler {
        /// The id of the handler.
        var id: UInt64
        /// The actual handler.
        var handler: () -> Void
    }

    struct State {
        /// The currently registered handlers.
        fileprivate var handlers = [Handler]()
        /// A counter to assign a unique number to each handler.
        fileprivate var handlerCounter: UInt64 = 0
        /// A boolean indicating if we have been shutdown already.
        fileprivate var isShuttingDown = false
        /// Continuations to resume after all of the handlers have been executed.
        fileprivate var gracefulShutdownFinishedContinuations = [CheckedContinuation<Void, Never>]()
    }

    private let state = LockedValueBox(State())

    var isShuttingDown: Bool {
        self.state.withLockedValue { return $0.isShuttingDown }
    }

    @_spi(TestKit)
    public init() {}

    func registerHandler(_ handler: @Sendable @escaping () -> Void) -> UInt64? {
        return self.state.withLockedValue { state in
            if state.isShuttingDown {
                // We are already shutting down so we just run the handler now.
                handler()
                return nil
            } else {
                defer {
                    state.handlerCounter += 1
                }
                let handlerID = state.handlerCounter
                state.handlers.append(.init(id: handlerID, handler: handler))

                return handlerID
            }
        }
    }

    func removeHandler(_ handlerID: UInt64) {
        self.state.withLockedValue { state in
            guard let index = state.handlers.firstIndex(where: { $0.id == handlerID }) else {
                // This can happen because if shutdownGracefully ran while the operation was still in progress
                return
            }

            state.handlers.remove(at: index)
        }
    }

    @_spi(TestKit)
    public func shutdownGracefully() {
        self.state.withLockedValue { state in
            guard !state.isShuttingDown else {
                return
            }
            state.isShuttingDown = true

            for handler in state.handlers {
                handler.handler()
            }

            state.handlers.removeAll()

            for continuation in state.gracefulShutdownFinishedContinuations {
                continuation.resume()
            }

            state.gracefulShutdownFinishedContinuations.removeAll()
        }
    }
}
