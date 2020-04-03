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

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin
#else
import Glibc
#endif
import Backtrace
import Dispatch
import Logging

public struct TopLevelLifecycle {
    private let lifecycle = Lifecycle(label: "\(TopLevelLifecycle.self)")

    /// Starts the provided `LifecycleItem` array and waits (blocking) until a shutdown `Signal` is captured or `Lifecycle.shutdown` is called on another thread.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - configuration: Defines lifecycle `Configuration`
    public func startAndWait(configuration: Configuration = .init()) throws {
        let waitSemaphore = DispatchSemaphore(value: 0)
        var startError: Error?

        self.start(configuration: configuration) { error in
            startError = error
            waitSemaphore.signal()
        }
        waitSemaphore.wait()
        try startError.map { throw $0 }
        self.wait()
    }

    /// Starts the provided `LifecycleItem` array.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - configuration: Defines lifecycle `Configuration`
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    public func start(configuration: Configuration = .init(), callback: @escaping (Error?) -> Void) {
        if configuration.installBacktrace {
            self.lifecycle.logger.info("installing backtrace")
            Backtrace.install()
        }
        configuration.shutdownSignal?.forEach { signal in
            self.lifecycle.logger.info("setting up shutdown hook on \(signal)")
            let signalSource = TopLevelLifecycle.trap(signal: signal, handler: { signal in
                self.lifecycle.logger.info("intercepted signal: \(signal)")
                self.shutdown()
           })
            self.lifecycle.shutdownGroup.notify(queue: DispatchQueue.global()) {
                signalSource.cancel()
            }
        }
        self.lifecycle.start(on: configuration.callbackQueue) { error in
            callback(error)
        }
    }

    /// Shuts down the `LifecycleItem` array provided in `start` or `startAndWait`.
    /// Shutdown is performed in reverse order of items provided./
    ///
    /// - parameters:
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    public func shutdown(callback: @escaping (Error?) -> Void = { _ in }) {
        self.lifecycle.shutdown(callback: callback)
    }

    /// Waits (blocking) until shutdown signal is captured or `Lifecycle.shutdown` is invoked on another thread.
    public func wait() {
        self.lifecycle.wait()
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - items: one or more `LifecycleItem`.
    func register(_ items: [LifecycleItem]) {
        self.lifecycle.register(items)
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - items: one or more `LifecycleItem`.
    internal func register(_ items: LifecycleItem...) {
        self.lifecycle.register(items)
    }

    /// Add a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - start: closure to perform the startup.
    ///    - shutdown: closure to perform the shutdown.
    func register(label: String, start: Lifecycle.Handler, shutdown: Lifecycle.Handler) {
        self.lifecycle.register(label: label, start: start, shutdown: shutdown)
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - shutdown: closure to perform the shutdown.
    func registerShutdown(label: String, _ handler: Lifecycle.Handler) {
        self.lifecycle.registerShutdown(label: label, handler)
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - start: closure to perform the shutdown.
    ///    - shutdown: closure to perform the shutdown.
    func register(label: String, start: @escaping () throws -> Void, shutdown: @escaping () throws -> Void) {
        self.lifecycle.register(label: label, start: start, shutdown: shutdown)
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - shutdown: closure to perform the shutdown.
    func registerShutdown(label: String, _ handler: @escaping () throws -> Void) {
        self.lifecycle.registerShutdown(label: label, handler)
    }
}

/// `Lifecycle` provides a basic mechanism to cleanly startup and shutdown the application, freeing resources in order before exiting.
public class Lifecycle: LifecycleItem {
    public let label: String
    internal let logger: Logger

    private var state = State.idle
    private let stateLock = Lock()

    private var items = [LifecycleItem]()
    private let itemsLock = Lock()

    internal let shutdownGroup = DispatchGroup()

    /// Creates a `Lifecycle` instance.
    public init(label: String) {
        self.label = label
        self.logger = Logger(label: "\(Lifecycle.self) \(label)")
        self.shutdownGroup.enter()
    }

    /// Starts the provided `LifecycleItem` array.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    public func start(callback: @escaping (Error?) -> Void) {
        self.start(on: DispatchQueue.global(), callback: callback)
    }

    /// Starts the provided `LifecycleItem` array.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - on: `DispatchQueue` to run the handler on
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    public func start(on queue: DispatchQueue, callback: @escaping (Error?) -> Void) {
        let items = self.itemsLock.withLock { self.items }
        self._start(on: queue, items: items, callback: callback)
    }

    /// Shuts down the `LifecycleItem` array provided in `start` or `startAndWait`.
    /// Shutdown is performed in reverse order of items provided.
    ///
    /// - parameters:
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    public func shutdown(callback: @escaping (Error?) -> Void = { _ in }) {
        self.shutdown(on: DispatchQueue.global(), callback: callback)
    }

    /// Shuts down the `LifecycleItem` array provided in `start` or `startAndWait`.
    /// Shutdown is performed in reverse order of items provided.
    ///
    /// - parameters:
    ///    - on: `DispatchQueue` to run the handler on
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    public func shutdown(on queue: DispatchQueue, callback: @escaping (Error?) -> Void = { _ in }) {
        self.stateLock.lock()
        switch self.state {
        case .idle:
            self.stateLock.unlock()
            self.shutdownGroup.leave()
        case .starting:
            self.state = .shuttingDown
            self.stateLock.unlock()
        case .shuttingDown, .shutdown:
            self.stateLock.unlock()
            return
        case .started(let items):
            self.state = .shuttingDown
            self.stateLock.unlock()
            self._shutdown(on: queue, items: items) { errors in
                defer { self.shutdownGroup.leave() }
                callback(errors.count > 0 ? ShutdownError(errors: errors) : nil)
            }
        }
    }

    public func wait() {
        self.shutdownGroup.wait()
    }

    // MARK: - private

    private func _start(on queue: DispatchQueue = DispatchQueue.global(), items: [LifecycleItem], callback: @escaping (Error?) -> Void) {
        self.stateLock.withLock {
            guard case .idle = self.state else {
                preconditionFailure("invalid state, \(self.state)")
            }
            precondition(items.count > 0, "invalid number of items, must be > 0")
            self.logger.info("starting lifecycle")

            self.state = .starting
        }
        self._start(on: queue, items: items, index: 0) { _, error in
            self.stateLock.lock()
            if error != nil {
                self.state = .shuttingDown
            }
            switch self.state {
            case .shuttingDown:
                self.stateLock.unlock()
                // shutdown was called while starting, or start failed, shutdown what we can
                self._shutdown(on: queue, items: items) { _ in
                    callback(error)
                    self.shutdownGroup.leave()
                }
            case .starting:
                self.state = .started(items)
                self.stateLock.unlock()
                return callback(nil)
            default:
                preconditionFailure("invalid state, \(self.state)")
            }
        }
    }

    private func _start(on queue: DispatchQueue, items: [LifecycleItem], index: Int, callback: @escaping (Int, Error?) -> Void) {
        // async barrier
        let start = { (callback) -> Void in queue.async { items[index].start(callback: callback) } }
        let callback = { (index, error) -> Void in queue.async { callback(index, error) } }

        if index >= items.count {
            return callback(index, nil)
        }
        self.logger.info("starting item [\(items[index].label)]")
        start { error in
            if let error = error {
                self.logger.error("failed to start [\(items[index].label)]: \(error)")
                return callback(index, error)
            }
            // shutdown called while starting
            if case .shuttingDown = self.stateLock.withLock({ self.state }) {
                return callback(index, nil)
            }
            self._start(on: queue, items: items, index: index + 1, callback: callback)
        }
    }

    private func _shutdown(on queue: DispatchQueue, items: [LifecycleItem], callback: @escaping ([String: Error]) -> Void) {
        self.stateLock.withLock {
            self.logger.info("shutting down lifecycle")
            self.state = .shuttingDown
        }
        self._shutdown(on: queue, items: items.reversed(), index: 0, errors: [:]) { errors in
            self.stateLock.withLock {
                guard case .shuttingDown = self.state else {
                    preconditionFailure("invalid state, \(self.state)")
                }
                self.state = .shutdown
            }
            self.logger.info("bye")
            callback(errors)
        }
    }

    private func _shutdown(on queue: DispatchQueue, items: [LifecycleItem], index: Int, errors: [String: Error], callback: @escaping ([String: Error]) -> Void) {
        // async barrier
        let shutdown = { (callback) -> Void in queue.async { items[index].shutdown(callback: callback) } }
        let callback = { (errors) -> Void in queue.async { callback(errors) } }

        if index >= items.count {
            return callback(errors)
        }
        self.logger.info("stopping item [\(items[index].label)]")
        shutdown { error in
            var errors = errors
            if let error = error {
                errors[items[index].label] = error
                self.logger.error("failed to stop [\(items[index].label)]: \(error)")
            }
            self._shutdown(on: queue, items: items, index: index + 1, errors: errors, callback: callback)
        }
    }

    private enum State {
        case idle
        case starting
        case started([LifecycleItem])
        case shuttingDown
        case shutdown
    }

    public struct ShutdownError: Error {
        let errors: [String: Error]
    }
}

extension Lifecycle {
    internal struct Item: LifecycleItem {
        let label: String
        let start: Handler
        let shutdown: Handler

        func start(callback: @escaping (Error?) -> Void) {
            self.start.run(callback: callback)
        }

        func shutdown(callback: @escaping (Error?) -> Void) {
            self.shutdown.run(callback: callback)
        }
    }
}

/// Adding items
public extension Lifecycle {
    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - items: one or more `LifecycleItem`.
    func register(_ items: [LifecycleItem]) {
        self.stateLock.withLock {
            guard case .idle = self.state else {
                preconditionFailure("invalid state, \(self.state)")
            }
        }
        self.itemsLock.withLock {
            self.items.append(contentsOf: items)
        }
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - items: one or more `LifecycleItem`.
    internal func register(_ items: LifecycleItem...) {
        self.register(items)
    }

    /// Add a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - start: closure to perform the startup.
    ///    - shutdown: closure to perform the shutdown.
    func register(label: String, start: Handler, shutdown: Handler) {
        self.register(Item(label: label, start: start, shutdown: shutdown))
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - shutdown: closure to perform the shutdown.
    func registerShutdown(label: String, _ handler: Handler) {
        self.register(label: label, start: .none, shutdown: handler)
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - start: closure to perform the shutdown.
    ///    - shutdown: closure to perform the shutdown.
    func register(label: String, start: @escaping () throws -> Void, shutdown: @escaping () throws -> Void) {
        self.register(label: label, start: .sync(start), shutdown: .sync(shutdown))
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - shutdown: closure to perform the shutdown.
    func registerShutdown(label: String, _ handler: @escaping () throws -> Void) {
        self.register(label: label, start: .none, shutdown: .sync(handler))
    }
}

/// Supported startup and shutdown method styles
public extension Lifecycle {
    struct Handler {
        private let body: (@escaping (Error?) -> Void) -> Void

        /// Initialize a `Lifecycle.Handler` based on a completion handler.
        ///
        /// - parameters:
        ///    - callback: the underlying completion handler
        public init(callback: @escaping (@escaping (Error?) -> Void) -> Void) {
            self.body = callback
        }

        /// Asynchronous `Lifecycle.Handler` based on a completion handler.
        ///
        /// - parameters:
        ///    - callback: the underlying completion handler
        public static func async(_ callback: @escaping (@escaping (Error?) -> Void) -> Void) -> Handler {
            return Handler(callback: callback)
        }

        /// Asynchronous `Lifecycle.Handler` based on a blocking, throwing function.
        ///
        /// - parameters:
        ///    - body: the underlying function
        public static func sync(_ body: @escaping () throws -> Void) -> Handler {
            return Handler { callback in
                do {
                    try body()
                    callback(nil)
                } catch {
                    callback(error)
                }
            }
        }

        /// Noop `Lifecycle.Handler`.
        public static var none: Handler {
            return Handler { callback in
                callback(nil)
            }
        }

        internal func run(callback: @escaping (Error?) -> Void) {
            self.body(callback)
        }
    }
}

/// Represents an item that can be started and shut down
public protocol LifecycleItem {
    var label: String { get }
    func start(callback: @escaping (Error?) -> Void)
    func shutdown(callback: @escaping (Error?) -> Void)
}

extension TopLevelLifecycle {
    /// `Lifecycle` configuration options.
    public struct Configuration {
        /// Defines the `DispatchQueue` on which startup and shutdown handlers are executed.
        public let callbackQueue: DispatchQueue
        /// Defines if to install a crash signal trap that prints backtraces.
        public let shutdownSignal: [Signal]?
        /// Defines what, if any, signals to trap for invoking shutdown.
        public let installBacktrace: Bool

        public init(callbackQueue: DispatchQueue = DispatchQueue.global(),
                    shutdownSignal: [Signal]? = [.TERM, .INT],
                    installBacktrace: Bool = true) {
            self.callbackQueue = callbackQueue
            self.shutdownSignal = shutdownSignal
            self.installBacktrace = installBacktrace
        }
    }
}

extension TopLevelLifecycle {
    /// Setup a signal trap.
    ///
    /// - parameters:
    ///    - signal: The signal to trap.
    ///    - handler: closure to invoke when the signal is captured.
    /// - returns: a `DispatchSourceSignal` for the given trap. The source must be cancled by the caller.
    public static func trap(signal sig: Signal, handler: @escaping (Signal) -> Void, queue: DispatchQueue = DispatchQueue.global()) -> DispatchSourceSignal {
        let signalSource = DispatchSource.makeSignalSource(signal: sig.rawValue, queue: queue)
        signal(sig.rawValue, SIG_IGN)
        signalSource.setEventHandler(handler: {
            signalSource.cancel()
            handler(sig)
        })
        signalSource.resume()
        return signalSource
    }

    /// A system signal
    public struct Signal {
        internal var rawValue: CInt

        public static let TERM: Signal = Signal(rawValue: SIGTERM)
        public static let INT: Signal = Signal(rawValue: SIGINT)
        // for testing
        internal static let ALRM: Signal = Signal(rawValue: SIGALRM)
    }
}
