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

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin
#else
import Glibc
#endif
import Backtrace
import Dispatch
import Logging

// MARK: - LifecycleTask

/// Represents an item that can be started and shut down
public protocol LifecycleTask {
    var label: String { get }
    func start(_ callback: @escaping (Error?) -> Void)
    func shutdown(_ callback: @escaping (Error?) -> Void)
}

// MARK: - LifecycleHandler

/// Supported startup and shutdown method styles
public struct LifecycleHandler {
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
    public static func async(_ callback: @escaping (@escaping (Error?) -> Void) -> Void) -> LifecycleHandler {
        return LifecycleHandler(callback)
    }

    /// Asynchronous `Lifecycle.Handler` based on a blocking, throwing function.
    ///
    /// - parameters:
    ///    - body: the underlying function
    public static func sync(_ body: @escaping () throws -> Void) -> LifecycleHandler {
        return LifecycleHandler { completionHandler in
            do {
                try body()
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    /// Noop `Lifecycle.Handler`.
    public static var none: LifecycleHandler {
        return LifecycleHandler { callback in
            callback(nil)
        }
    }

    internal func run(_ callback: @escaping (Error?) -> Void) {
        self.body(callback)
    }
}

// MARK: - ServiceLifecycle

public struct ServiceLifecycle {
    private let configuration: Configuration
    private let lifecycle: ComponentLifecycle

    /// Creates a `ComponentLifecycle` instance.
    ///
    /// - parameters:
    ///    - configuration: Defines lifecycle `Configuration`
    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        self.lifecycle = ComponentLifecycle(label: "Lifecycle", logger: self.configuration.logger)
        // setup backtrace trap as soon as possible
        if configuration.installBacktrace {
            self.lifecycle.log("installing backtrace")
            Backtrace.install()
        }
    }

    /// Starts the provided `LifecycleItem` array.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    public func start(_ callback: @escaping (Error?) -> Void) {
        self.configuration.shutdownSignal?.forEach { signal in
            self.lifecycle.log("setting up shutdown hook on \(signal)")
            let signalSource = ServiceLifecycle.trap(signal: signal, handler: { signal in
                self.lifecycle.log("intercepted signal: \(signal)")
                self.shutdown()
           })
            self.lifecycle.shutdownGroup.notify(queue: .global()) {
                signalSource.cancel()
            }
        }
        self.lifecycle.start(on: self.configuration.callbackQueue, callback)
    }

    /// Starts the provided `LifecycleItem` array and waits (blocking) until a shutdown `Signal` is captured or `shutdown` is called on another thread.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - configuration: Defines lifecycle `Configuration`
    public func startAndWait() throws {
        try self.lifecycle.startAndWait(on: self.configuration.callbackQueue)
    }

    /// Shuts down the `LifecycleItem` array provided in `start` or `startAndWait`.
    /// Shutdown is performed in reverse order of items provided.
    ///
    /// - parameters:
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    public func shutdown(_ callback: @escaping (Error?) -> Void = { _ in }) {
        self.lifecycle.shutdown(callback)
    }

    /// Waits (blocking) until shutdown `Signal` is captured or `shutdown` is invoked on another thread.
    public func wait() {
        self.lifecycle.wait()
    }
}

extension ServiceLifecycle {
    /// Setup a signal trap.
    ///
    /// - parameters:
    ///    - signal: The signal to trap.
    ///    - handler: closure to invoke when the signal is captured.
    /// - returns: a `DispatchSourceSignal` for the given trap. The source must be cancelled by the caller.
    public static func trap(signal sig: Signal, handler: @escaping (Signal) -> Void, on queue: DispatchQueue = .global()) -> DispatchSourceSignal {
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
    public struct Signal: Equatable, CustomStringConvertible {
        internal var rawValue: CInt

        public static let TERM = Signal(rawValue: SIGTERM)
        public static let INT = Signal(rawValue: SIGINT)
        // for testing
        internal static let ALRM = Signal(rawValue: SIGALRM)

        public var description: String {
            var result = "Signal("
            switch self {
            case Signal.TERM: result += "TERM, "
            case Signal.INT: result += "INT, "
            case Signal.ALRM: result += "ALRM, "
            default: () // ok to ignore
            }
            result += "rawValue: \(self.rawValue))"
            return result
        }
    }
}

public extension ServiceLifecycle {
    /// Adds a `Task` to a `Tasks` collection.
    ///
    /// - parameters:
    ///    - tasks: one or more `Tasks`.
    func register(_ tasks: LifecycleTask ...) {
        self.lifecycle.register(tasks)
    }

    /// Adds a `Task` to a `Tasks` collection.
    ///
    /// - parameters:
    ///    - tasks: array of `Tasks`.
    func register(_ tasks: [LifecycleTask]) {
        self.lifecycle.register(tasks)
    }

    /// Adds a `Task` to a `Tasks` collection.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - start: `Handler` to perform the startup.
    ///    - shutdown: `Handler` to perform the shutdown.
    func register(label: String, start: LifecycleHandler, shutdown: LifecycleHandler) {
        self.lifecycle.register(label: label, start: start, shutdown: shutdown)
    }

    /// Adds a `Task` to a `Tasks` collection.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - handler: `Handler` to perform the shutdown.
    func registerShutdown(label: String, _ handler: LifecycleHandler) {
        self.lifecycle.registerShutdown(label: label, handler)
    }
}

extension ServiceLifecycle {
    /// `Lifecycle` configuration options.
    public struct Configuration {
        /// Defines the `Logger` to log with.
        public var logger: Logger
        /// Defines the `DispatchQueue` on which startup and shutdown callback handlers are run.
        public var callbackQueue: DispatchQueue
        /// Defines if to install a crash signal trap that prints backtraces.
        public var shutdownSignal: [Signal]?
        /// Defines what, if any, signals to trap for invoking shutdown.
        public var installBacktrace: Bool

        public init(logger: Logger = Logger(label: "Lifeycle"),
                    callbackQueue: DispatchQueue = .global(),
                    shutdownSignal: [Signal]? = [.TERM, .INT],
                    installBacktrace: Bool = true) {
            self.logger = logger
            self.callbackQueue = callbackQueue
            self.shutdownSignal = shutdownSignal
            self.installBacktrace = installBacktrace
        }
    }
}

struct ShutdownError: Error {
    public let errors: [String: Error]
}

// MARK: - ComponentLifecycle

/// `Lifecycle` provides a basic mechanism to cleanly startup and shutdown the application, freeing resources in order before exiting.
public class ComponentLifecycle: LifecycleTask {
    public let label: String
    private let logger: Logger
    internal let shutdownGroup = DispatchGroup()

    private var state = State.idle
    private let stateLock = Lock()

    private var tasks = [LifecycleTask]()
    private let tasksLock = Lock()

    /// Creates a `ComponentLifecycle` instance.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - logger: `Logger` to log with.
    public init(label: String, logger: Logger? = nil) {
        self.label = label
        self.logger = logger ?? Logger(label: label)
        self.shutdownGroup.enter()
    }

    /// Starts the provided `LifecycleItem` array.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    public func start(_ callback: @escaping (Error?) -> Void) {
        self.start(on: .global(), callback)
    }

    /// Starts the provided `LifecycleItem` array.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - on: `DispatchQueue` to run the handlers callback  on
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    public func start(on queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        let tasks = self.tasksLock.withLock { self.tasks }
        self._start(on: queue, tasks: tasks, callback: callback)
    }

    /// Starts the provided `LifecycleItem` array and waits (blocking) until `shutdown` is called on another thread.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - on: `DispatchQueue` to run the handlers callback on
    public func startAndWait(on queue: DispatchQueue = .global()) throws {
        var startError: Error?
        let startSemaphore = DispatchSemaphore(value: 0)

        self.start(on: queue) { error in
            startError = error
            startSemaphore.signal()
        }
        startSemaphore.wait()
        try startError.map { throw $0 }
        self.wait()
    }

    /// Shuts down the `LifecycleItem` array provided in `start` or `startAndWait`.
    /// Shutdown is performed in reverse order of items provided.
    public func shutdown(_ callback: @escaping (Error?) -> Void = { _ in }) {
        let setupShutdownListener = { (queue: DispatchQueue) in
            self.shutdownGroup.notify(queue: queue) {
                guard case .shutdown(let errors) = self.state else {
                    preconditionFailure("invalid state, \(self.state)")
                }
                callback(errors.flatMap(Lifecycle.ShutdownError.init))
            }
        }

        self.stateLock.lock()
        switch self.state {
        case .idle:
            self.state = .shutdown(nil)
            self.stateLock.unlock()
            defer { self.shutdownGroup.leave() }
            callback(nil)
        case .shutdown:
            self.stateLock.unlock()
            self.log(level: .warning, "already shutdown")
            callback(nil)
        case .starting(let queue):
            self.state = .shuttingDown(queue)
            self.stateLock.unlock()
            setupShutdownListener(queue)
        case .shuttingDown(let queue):
            self.stateLock.unlock()
            setupShutdownListener(queue)
        case .started(let queue, let tasks):
            self.state = .shuttingDown(queue)
            self.stateLock.unlock()
            setupShutdownListener(queue)
            self._shutdown(on: queue, tasks: tasks, callback: self.shutdownGroup.leave)
        }
    }

    /// Waits (blocking) until `shutdown` is invoked on another thread.
    public func wait() {
        self.shutdownGroup.wait()
    }

    // MARK: - private

    private func _start(on queue: DispatchQueue, tasks: [LifecycleTask], callback: @escaping (Error?) -> Void) {
        precondition(tasks.count > 0, "invalid number of tasks, must be > 0")
        self.stateLock.withLock {
            guard case .idle = self.state else {
                preconditionFailure("invalid state, \(self.state)")
            }
            log("starting")
            self.state = .starting(queue)
        }
        self.startTask(on: queue, tasks: tasks, index: 0) { started, error in
            self.stateLock.lock()
            if error != nil {
                self.state = .shuttingDown(queue)
            }
            switch self.state {
            case .shuttingDown:
                self.stateLock.unlock()
                // shutdown was called while starting, or start failed, shutdown what we can
                let stoppable = started < tasks.count ? Array(tasks.prefix(started + 1)) : tasks
                self._shutdown(on: queue, tasks: stoppable) {
                    callback(error)
                    self.shutdownGroup.leave()
                }
            case .starting:
                self.state = .started(queue, tasks)
                self.stateLock.unlock()
                callback(nil)
            default:
                preconditionFailure("invalid state, \(self.state)")
            }
        }
    }

    private func startTask(on queue: DispatchQueue, tasks: [LifecycleTask], index: Int, callback: @escaping (Int, Error?) -> Void) {
        // async barrier
        let start = { (callback) -> Void in queue.async { tasks[index].start(callback) } }
        let callback = { (index, error) -> Void in queue.async { callback(index, error) } }

        if index >= tasks.count {
            return callback(index, nil)
        }
        self.log("starting tasks [\(tasks[index].label)]")
        start { error in
            if let error = error {
                self.log(level: .error, "failed to start [\(tasks[index].label)]: \(error)")
                return callback(index, error)
            }
            // shutdown called while starting
            if case .shuttingDown = self.stateLock.withLock({ self.state }) {
                return callback(index, nil)
            }
            self.startTask(on: queue, tasks: tasks, index: index + 1, callback: callback)
        }
    }

    private func _shutdown(on queue: DispatchQueue, tasks: [LifecycleTask], callback: @escaping () -> Void) {
        self.stateLock.withLock {
            log("shutting down")
            self.state = .shuttingDown(queue)
        }
        self.shutdownTask(on: queue, tasks: tasks.reversed(), index: 0, errors: nil) { errors in
            self.stateLock.withLock {
                guard case .shuttingDown = self.state else {
                    preconditionFailure("invalid state, \(self.state)")
                }
                self.state = .shutdown(errors)
            }
            self.log("bye")
            callback()
        }
    }

    private func shutdownTask(on queue: DispatchQueue, tasks: [LifecycleTask], index: Int, errors: [String: Error]?, callback: @escaping ([String: Error]?) -> Void) {
        // async barrier
        let shutdown = { (callback) -> Void in queue.async { tasks[index].shutdown(callback) } }
        let callback = { (errors) -> Void in queue.async { callback(errors) } }

        if index >= tasks.count {
            return callback(errors)
        }
        self.log("stopping tasks [\(tasks[index].label)]")
        shutdown { error in
            var errors = errors
            if let error = error {
                if errors == nil {
                    errors = [:]
                }
                errors![tasks[index].label] = error
                self.log(level: .error, "failed to stop [\(tasks[index].label)]: \(error)")
            }
            self.shutdownTask(on: queue, tasks: tasks, index: index + 1, errors: errors, callback: callback)
        }
    }

    internal func log(level: Logger.Level = .info, _ message: String) {
        self.logger.log(level: level, "[\(self.label)] \(message)")
    }

    private enum State {
        case idle
        case starting(DispatchQueue)
        case started(DispatchQueue, [LifecycleTask])
        case shuttingDown(DispatchQueue)
        case shutdown([String: Error]?)
    }
}

public extension ComponentLifecycle {
    internal struct Task: LifecycleTask {
        let label: String
        let start: LifecycleHandler
        let shutdown: LifecycleHandler

        func start(_ callback: @escaping (Error?) -> Void) {
            self.start.run(callback)
        }

        func shutdown(_ callback: @escaping (Error?) -> Void) {
            self.shutdown.run(callback)
        }
    }

    /// Adds a `Task` to a `Tasks` collection.
    ///
    /// - parameters:
    ///    - tasks: one or more `Tasks`.
    func register(_ tasks: LifecycleTask ...) {
        self.register(tasks)
    }

    /// Adds a `Task` to a `Tasks` collection.
    ///
    /// - parameters:
    ///    - tasks: array of `Tasks`.
    func register(_ tasks: [LifecycleTask]) {
        self.stateLock.withLock {
            guard case .idle = self.state else {
                preconditionFailure("invalid state, \(self.state)")
            }
        }
        self.tasksLock.withLock {
            self.tasks.append(contentsOf: tasks)
        }
    }

    /// Adds a `Task` to a `Tasks` collection.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - start: `Handler` to perform the startup.
    ///    - shutdown: `Handler` to perform the shutdown.
    func register(label: String, start: LifecycleHandler, shutdown: LifecycleHandler) {
        self.register(Task(label: label, start: start, shutdown: shutdown))
    }

    /// Adds a `Task` to a `Tasks` collection.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - handler: `Handler` to perform the shutdown.
    func registerShutdown(label: String, _ handler: LifecycleHandler) {
        self.register(label: label, start: .none, shutdown: handler)
    }
}
