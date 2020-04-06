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

/// `Lifecycle` provides a basic mechanism to cleanly startup and shutdown the application, freeing resources in order before exiting.
public class Lifecycle {
    private let logger = Logger(label: "\(Lifecycle.self)")
    private let shutdownGroup = DispatchGroup()

    private var state = State.idle
    private let stateLock = Lock()

    private var items = [LifecycleItem]()
    private let itemsLock = Lock()

    private let queue = DispatchQueue(label: "lifecycle", attributes: .concurrent)

    /// Creates a `Lifecycle` instance.
    public init() {
        self.shutdownGroup.enter()
    }

    /// Starts the provided `LifecycleItem` array and waits (blocking) until a shutdown `Signal` is captured or `Lifecycle.shutdown` is called on another thread.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - configuration: Defines lifecycle `Configuration`
    public func startAndWait(configuration: Configuration = .init()) throws {
        let lock = Lock()
        var startError: Error?
        self.start(configuration: configuration) { error in
            lock.withLock {
                startError = error
            }
        }
        self.wait()
        try lock.withLock {
            startError
        }.map { error in
            throw error
        }
    }

    /// Starts the provided `LifecycleItem` array.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - configuration: Defines lifecycle `Configuration`
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    public func start(configuration: Configuration = .init(), callback: @escaping (Error?) -> Void) {
        let items = self.itemsLock.withLock { self.items }
        self._start(configuration: configuration, items: items) { error in
            // TODO: should the queue be another config option?
            DispatchQueue.global().async {
                callback(error)
            }
        }
    }

    /// Shuts down the `LifecycleItem` array provided in `start` or `startAndWait`.
    /// Shutdown is performed in reverse order of items provided.
    ///
    /// - parameters:
    ///    - callback: The handler which is called after the shutdown operation completes. The parameter will be `nil` on success and contain a `[String: Error]` otherwise.
    public func shutdown(callback: @escaping ([String: Error]?) -> Void = { _ in }) {
        let setupShutdownListener = {
            // TODO: should the queue be another config option?
            self.shutdownGroup.notify(queue: DispatchQueue.global()) {
                guard case .shutdown(let errors) = self.state else {
                    preconditionFailure("invalid state, \(self.state)")
                }
                callback(errors)
            }
        }

        self.stateLock.lock()
        switch self.state {
        case .idle:
            self.state = .shutdown(nil)
            self.stateLock.unlock()
            setupShutdownListener()
            self.shutdownGroup.leave()
        case .shutdown(let errors):
            self.stateLock.unlock()
            self.logger.warning("already shutdown")
            callback(errors)
        case .starting:
            self.state = .shuttingDown
            self.stateLock.unlock()
            setupShutdownListener()
        case .shuttingDown:
            self.stateLock.unlock()
            setupShutdownListener()
        case .started(let configuration, let items):
            self.state = .shuttingDown
            self.stateLock.unlock()
            setupShutdownListener()
            self._shutdown(configuration: configuration, items: items, callback: self.shutdownGroup.leave)
        }
    }

    /// Waits (blocking) until shutdown signal is captured or `Lifecycle.shutdown` is invoked on another thread.
    public func wait() {
        self.shutdownGroup.wait()
    }

    // MARK: - private

    private func _start(configuration: Configuration, items: [LifecycleItem], callback: @escaping (Error?) -> Void) {
        self.stateLock.withLock {
            guard case .idle = self.state else {
                preconditionFailure("invalid state, \(self.state)")
            }
            precondition(items.count > 0, "invalid number of items, must be > 0")
            self.logger.info("starting lifecycle")
            if configuration.installBacktrace {
                self.logger.info("installing backtrace")
                Backtrace.install()
            }
            self.state = .starting
        }
        self.startItem(configuration: configuration, items: items, index: 0) { started, error in
            self.stateLock.lock()
            if error != nil {
                self.state = .shuttingDown
            }
            switch self.state {
            case .shuttingDown:
                self.stateLock.unlock()
                // shutdown was called while starting, or start failed, shutdown what we can
                let stoppable = started < items.count ? Array(items.prefix(started + 1)) : items
                self._shutdown(configuration: configuration, items: stoppable) {
                    callback(error)
                    self.shutdownGroup.leave()
                }
            case .starting:
                self.state = .started(configuration, items)
                self.stateLock.unlock()
                configuration.shutdownSignal?.forEach { signal in
                    self.logger.info("setting up shutdown hook on \(signal)")
                    let signalSource = Lifecycle.trap(signal: signal, handler: { signal in
                        self.logger.info("intercepted signal: \(signal)")
                        self.shutdown()
                    })
                    self.shutdownGroup.notify(queue: DispatchQueue.global()) {
                        signalSource.cancel()
                    }
                }
                return callback(nil)
            default:
                preconditionFailure("invalid state, \(self.state)")
            }
        }
    }

    private func startItem(configuration: Configuration, items: [LifecycleItem], index: Int, callback: @escaping (Int, Error?) -> Void) {
        if index >= items.count {
            return callback(index, nil)
        }

        let startCompletionHandler = { (error: Error?) -> Void in
            if let error = error {
                self.logger.error("failed to start [\(items[index].label)]: \(error)")
                return callback(index, error)
            }
            // shutdown called while starting
            if case .shuttingDown = self.stateLock.withLock({ self.state }) {
                return callback(index, nil)
            }
            self.startItem(configuration: configuration, items: items, index: index + 1, callback: callback)
        }

        var startTask: DispatchWorkItem?
        var startTimoutTask: DispatchWorkItem?

        // start
        startTask = DispatchWorkItem {
            // user's code runs on provided configuration.callbackQueue
            configuration.callbackQueue.async {
                items[index].start { error in
                    // lifecycle code runs on self.queue
                    self.queue.async {
                        if startTask?.isCancelled ?? true {
                            return
                        }
                        startTimoutTask?.cancel()
                        startCompletionHandler(error)
                    }
                }
            }
        }

        // start timeout
        startTimeoutTask = DispatchWorkItem {
            if startTimoutTask?.isCancelled ?? true {
                return
            }
            startTask?.cancel()
            startCompletionHandler(TimeoutError())
        }

        self.logger.info("starting item [\(items[index].label)]")
        // lifecycle code runs on self.queue
        self.queue.async(execute: startTask!)
        self.queue.asyncAfter(deadline: .now() + configuration.timeout, execute: startTimoutTask!)
    }

    private func _shutdown(configuration: Configuration, items: [LifecycleItem], callback: @escaping () -> Void) {
        self.stateLock.withLock {
            self.logger.info("shutting down lifecycle")
            self.state = .shuttingDown
        }
        self.shutdownItem(configuration: configuration, items: items.reversed(), index: 0, errors: nil) { errors in
            self.stateLock.withLock {
                guard case .shuttingDown = self.state else {
                    preconditionFailure("invalid state, \(self.state)")
                }
                self.state = .shutdown(errors)
            }
            self.logger.info("bye")
            callback()
        }
    }

    private func shutdownItem(configuration: Configuration, items: [LifecycleItem], index: Int, errors: [String: Error]?, callback: @escaping ([String: Error]?) -> Void) {
        if index >= items.count {
            return callback(errors)
        }

        let shutdownCompletionHandler = { (error: Error?) -> Void in
            var errors = errors
            if let error = error {
                if errors == nil {
                    errors = [:]
                }
                errors![items[index].label] = error
                self.logger.error("failed to stop [\(items[index].label)]: \(error)")
            }
            self.shutdownItem(configuration: configuration, items: items, index: index + 1, errors: errors, callback: callback)
        }

        var shutdownTask: DispatchWorkItem?
        var shutdownTimeoutTask: DispatchWorkItem?

        // shutdown
        shutdownTask = DispatchWorkItem {
            // user's code runs on provided configuration.callbackQueue
            configuration.callbackQueue.async {
                items[index].shutdown { error in
                    // lifecycle code runs on self.queue
                    self.queue.async {
                        if shutdownTask?.isCancelled ?? true {
                            return
                        }
                        shutdownTimoutTask?.cancel()
                        shutdownCompletionHandler(error)
                    }
                }
            }
        }

        // start timeout
        shutdownTimoutTask = DispatchWorkItem {
            if shutdownTimoutTask?.isCancelled ?? true {
                return
            }
            shutdownTask?.cancel()
            shutdownCompletionHandler(TimeoutError())
        }

        self.logger.info("stopping item [\(items[index].label)]")
        // lifecycle code runs on self.queue
        self.queue.async(execute: shutdownTask!)
        self.queue.asyncAfter(deadline: .now() + configuration.timeout, execute: shutdownTimoutTask!)
    }

    private enum State {
        case idle
        case starting
        case started(Configuration, [LifecycleItem])
        case shuttingDown
        case shutdown([String: Error]?)
    }
}

extension Lifecycle {
    public struct TimeoutError: Error {}
}

extension Lifecycle {
    internal struct Item: LifecycleItem {
        let label: String
        let start: Handler
        let shutdown: Handler

        func start(callback: @escaping (Error?) -> Void) {
            self.start.run(callback)
        }

        func shutdown(callback: @escaping (Error?) -> Void) {
            self.shutdown.run(callback)
        }
    }
}

extension Lifecycle {
    /// `Lifecycle` configuration options.
    public struct Configuration {
        /// Defines the `DispatchQueue` on which startup and shutdown handlers are executed.
        public let callbackQueue: DispatchQueue
        /// Defines timeout for `LifecycleItem` start and shutdown operations.
        public let timeout: DispatchTimeInterval
        /// Defines what, if any, signals to trap for invoking shutdown.
        public let shutdownSignal: [Signal]?
        /// Defines if to install a crash signal trap that prints backtraces.
        public let installBacktrace: Bool

        /// Initializes a `Configuration`.
        ///
        /// - parameters:
        ///    - callbackQueue: Defines the `DispatchQueue` on which startup and shutdown handlers are executed.
        ///    - timeout: Defines timeout for `LifecycleItem` start and shutdown operations.
        ///    - shutdownSignal: Defines what, if any, signals to trap for invoking shutdown.
        ///    - installBacktrace: Defines if to install a crash signal trap that prints backtraces.
        public init(callbackQueue: DispatchQueue = DispatchQueue.global(),
                    timeout: DispatchTimeInterval = .seconds(5),
                    shutdownSignal: [Signal]? = [.TERM, .INT],
                    installBacktrace: Bool = true) {
            self.callbackQueue = callbackQueue
            self.timeout = timeout
            self.shutdownSignal = shutdownSignal
            self.installBacktrace = installBacktrace
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
        public init(_ callback: @escaping (@escaping (Error?) -> Void) -> Void) {
            self.body = callback
        }

        /// Asynchronous `Lifecycle.Handler` based on a completion handler.
        ///
        /// - parameters:
        ///    - callback: the underlying completion handler
        public static func async(_ callback: @escaping (@escaping (Error?) -> Void) -> Void) -> Handler {
            return Handler(callback)
        }

        /// Asynchronous `Lifecycle.Handler` based on a blocking, throwing function.
        ///
        /// - parameters:
        ///    - body: the underlying function
        public static func sync(_ body: @escaping () throws -> Void) -> Handler {
            return Handler { completionHandler in
                do {
                    try body()
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }

        /// Noop `Lifecycle.Handler`.
        public static var none: Handler {
            return Handler { callback in
                callback(nil)
            }
        }

        internal func run(_ callback: @escaping (Error?) -> Void) {
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

extension Lifecycle {
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
