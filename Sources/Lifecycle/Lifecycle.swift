//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftServiceLifecycle open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the SwiftServiceLifecycle project authors
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
import CoreMetrics
import Dispatch
import Logging

// MARK: - LifecycleTask

/// Represents an item that can be started and shut down
public protocol LifecycleTask {
    var label: String { get }
    var shutdownIfNotStarted: Bool { get }
    func start(_ callback: @escaping (Error?) -> Void)
    func shutdown(_ callback: @escaping (Error?) -> Void)
    var logStart: Bool { get }
    var logShutdown: Bool { get }
}

extension LifecycleTask {
    public var shutdownIfNotStarted: Bool {
        return false
    }

    public var logStart: Bool {
        return true
    }

    public var logShutdown: Bool {
        return true
    }
}

// MARK: - LifecycleHandler

/// Supported startup and shutdown method styles
public struct LifecycleHandler {
    @available(*, deprecated)
    public typealias Callback = (@escaping (Error?) -> Void) -> Void

    private let underlying: ((@escaping (Error?) -> Void) -> Void)?

    /// Initialize a `LifecycleHandler` based on a completion handler.
    ///
    /// - parameters:
    ///    - handler: the underlying completion handler
    public init(_ handler: ((@escaping (Error?) -> Void) -> Void)?) {
        self.underlying = handler
    }

    /// Asynchronous `LifecycleHandler` based on a completion handler.
    ///
    /// - parameters:
    ///    - handler: the underlying async handler
    public static func async(_ handler: @escaping (@escaping (Error?) -> Void) -> Void) -> LifecycleHandler {
        return LifecycleHandler(handler)
    }

    /// Asynchronous `LifecycleHandler` based on a blocking, throwing function.
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

    /// Noop `LifecycleHandler`.
    public static var none: LifecycleHandler {
        return LifecycleHandler(nil)
    }

    internal func run(_ completionHandler: @escaping (Error?) -> Void) {
        let body = self.underlying ?? { callback in
            callback(nil)
        }
        body(completionHandler)
    }

    internal var noop: Bool {
        return self.underlying == nil
    }
}

#if canImport(_Concurrency) && compiler(>=5.5.2)
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension LifecycleHandler {
    public init(_ handler: @escaping () async throws -> Void) {
        self = LifecycleHandler { callback in
            Task {
                do {
                    try await handler()
                    callback(nil)
                } catch {
                    callback(error)
                }
            }
        }
    }

    public static func async(_ handler: @escaping () async throws -> Void) -> LifecycleHandler {
        return LifecycleHandler(handler)
    }
}
#endif

// MARK: - Stateful Lifecycle Handlers

/// LifecycleHandler for starting stateful tasks. The state can then be fed into a LifecycleShutdownHandler
public struct LifecycleStartHandler<State> {
    private let underlying: (@escaping (Result<State, Error>) -> Void) -> Void

    /// Initialize a `LifecycleHandler` based on a completion handler.
    ///
    /// - parameters:
    ///    - callback: the underlying completion handler
    public init(_ handler: @escaping (@escaping (Result<State, Error>) -> Void) -> Void) {
        self.underlying = handler
    }

    /// Asynchronous `LifecycleStartHandler` based on a completion handler.
    ///
    /// - parameters:
    ///    - handler: the underlying async handler
    public static func async(_ handler: @escaping (@escaping (Result<State, Error>) -> Void) -> Void) -> LifecycleStartHandler {
        return LifecycleStartHandler(handler)
    }

    /// Synchronous `LifecycleStartHandler` based on a blocking, throwing function.
    ///
    /// - parameters:
    ///    - body: the underlying function
    public static func sync(_ body: @escaping () throws -> State) -> LifecycleStartHandler {
        return LifecycleStartHandler { completionHandler in
            do {
                let state = try body()
                completionHandler(.success(state))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }

    internal func run(_ completionHandler: @escaping (Result<State, Error>) -> Void) {
        self.underlying(completionHandler)
    }
}

#if canImport(_Concurrency) && compiler(>=5.5.2)
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension LifecycleStartHandler {
    public init(_ handler: @escaping () async throws -> State) {
        self = LifecycleStartHandler { callback in
            Task {
                do {
                    let state = try await handler()
                    callback(.success(state))
                } catch {
                    callback(.failure(error))
                }
            }
        }
    }

    public static func async(_ handler: @escaping () async throws -> State) -> LifecycleStartHandler {
        return LifecycleStartHandler(handler)
    }
}
#endif

/// LifecycleHandler for shutting down stateful tasks. The state comes from a LifecycleStartHandler
public struct LifecycleShutdownHandler<State> {
    private let underlying: (State, @escaping (Error?) -> Void) -> Void

    /// Initialize a `LifecycleShutdownHandler` based on a completion handler.
    ///
    /// - parameters:
    ///    - handler: the underlying completion handler
    public init(_ handler: @escaping (State, @escaping (Error?) -> Void) -> Void) {
        self.underlying = handler
    }

    /// Asynchronous `LifecycleShutdownHandler` based on a completion handler.
    ///
    /// - parameters:
    ///    - handler: the underlying async handler
    public static func async(_ handler: @escaping (State, @escaping (Error?) -> Void) -> Void) -> LifecycleShutdownHandler {
        return LifecycleShutdownHandler(handler)
    }

    /// Asynchronous `LifecycleShutdownHandler` based on a blocking, throwing function.
    ///
    /// - parameters:
    ///    - body: the underlying function
    public static func sync(_ body: @escaping (State) throws -> Void) -> LifecycleShutdownHandler {
        return LifecycleShutdownHandler { state, completionHandler in
            do {
                try body(state)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    internal func run(state: State, _ completionHandler: @escaping (Error?) -> Void) {
        self.underlying(state, completionHandler)
    }
}

#if canImport(_Concurrency) && compiler(>=5.5.2)
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension LifecycleShutdownHandler {
    public init(_ handler: @escaping (State) async throws -> Void) {
        self = LifecycleShutdownHandler { state, callback in
            Task {
                do {
                    try await handler(state)
                    callback(nil)
                } catch {
                    callback(error)
                }
            }
        }
    }

    public static func async(_ handler: @escaping (State) async throws -> Void) -> LifecycleShutdownHandler {
        return LifecycleShutdownHandler(handler)
    }
}
#endif

// MARK: - ServiceLifecycle

/// `ServiceLifecycle` provides a basic mechanism to cleanly startup and shutdown the application, freeing resources in order before exiting.
///  By default, also install shutdown hooks based on `Signal` and backtraces.
public struct ServiceLifecycle {
    private static let backtracesInstalled = AtomicBoolean(false)

    private let configuration: Configuration

    /// The underlying `ComponentLifecycle` instance
    private let underlying: ComponentLifecycle

    /// Creates a `ServiceLifecycle` instance.
    ///
    /// - parameters:
    ///    - configuration: Defines lifecycle `Configuration`
    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        self.underlying = ComponentLifecycle(label: self.configuration.label, logger: self.configuration.logger)
        // setup backtraces as soon as possible, so if we crash during setup we get a backtrace
        self.installBacktrace()
    }

    /// Starts the provided `LifecycleTask` array.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    public func start(_ callback: @escaping (Error?) -> Void) {
        guard self.underlying.idle else {
            preconditionFailure("already started")
        }
        self.setupShutdownHook()
        self.underlying.start(on: self.configuration.callbackQueue, callback)
    }

    /// Starts the provided `LifecycleTask` array and waits (blocking) until a shutdown `Signal` is captured or `shutdown` is called on another thread.
    /// Startup is performed in the order of items provided.
    public func startAndWait() throws {
        guard self.underlying.idle else {
            preconditionFailure("already started")
        }
        self.setupShutdownHook()
        try self.underlying.startAndWait(on: self.configuration.callbackQueue)
    }

    /// Shuts down the `LifecycleTask` array provided in `start` or `startAndWait`.
    /// Shutdown is performed in reverse order of items provided.
    ///
    /// - parameters:
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    public func shutdown(_ callback: @escaping (Error?) -> Void = { _ in }) {
        self.underlying.shutdown(callback)
    }

    /// Waits (blocking) until shutdown `Signal` is captured or `shutdown` is invoked on another thread.
    public func wait() {
        self.underlying.wait()
    }

    private func installBacktrace() {
        if self.configuration.installBacktrace, ServiceLifecycle.backtracesInstalled.compareAndSwap(expected: false, desired: true) {
            self.log("installing backtrace")
            Backtrace.install()
        }
    }

    private func setupShutdownHook() {
        self.configuration.shutdownSignal?.forEach { signal in
            self.log("setting up shutdown hook on \(signal)")
            let signalSource = ServiceLifecycle.trap(signal: signal, handler: { signal in
                self.log("intercepted signal: \(signal)")
                self.shutdown()
            }, cancelAfterTrap: true)
            // register cleanup as the last task
            self.registerShutdown(label: "\(signal) shutdown hook cleanup", .sync {
                // cancel if not already canceled by the trap
                if !signalSource.isCancelled {
                    signalSource.cancel()
                    ServiceLifecycle.removeTrap(signal: signal)
                }
            })
        }
    }

    private func log(_ message: String) {
        self.underlying.logger.info("\(message)")
    }
}

extension ServiceLifecycle {
    private static var trapped: Set<Int32> = []
    private static let trappedLock = Lock()

    /// Setup a signal trap.
    ///
    /// - parameters:
    ///    - signal: The signal to trap.
    ///    - handler: closure to invoke when the signal is captured.
    ///    - on: DispatchQueue to run the signal handler on (default global dispatch queue)
    ///    - cancelAfterTrap: Defaults to false, which means the signal handler can be run multiple times. If true, the DispatchSignalSource will be cancelled after being trapped once.
    /// - returns: a `DispatchSourceSignal` for the given trap. The source must be cancelled by the caller.
    public static func trap(signal sig: Signal, handler: @escaping (Signal) -> Void, on queue: DispatchQueue = .global(), cancelAfterTrap: Bool = false) -> DispatchSourceSignal {
        // on linux, we can call singal() once per process
        self.trappedLock.withLockVoid {
            if !self.trapped.contains(sig.rawValue) {
                signal(sig.rawValue, SIG_IGN)
                self.trapped.insert(sig.rawValue)
            }
        }
        let signalSource = DispatchSource.makeSignalSource(signal: sig.rawValue, queue: queue)
        signalSource.setEventHandler {
            // run handler first
            handler(sig)
            // then cancel trap if so requested
            if cancelAfterTrap {
                signalSource.cancel()
                self.removeTrap(signal: sig)
            }
        }
        signalSource.resume()
        return signalSource
    }

    public static func removeTrap(signal sig: Signal) {
        self.trappedLock.withLockVoid {
            if self.trapped.contains(sig.rawValue) {
                signal(sig.rawValue, SIG_DFL)
                self.trapped.remove(sig.rawValue)
            }
        }
    }

    /// A system signal
    public struct Signal: Equatable, CustomStringConvertible {
        internal var rawValue: CInt

        public static let TERM = Signal(rawValue: SIGTERM)
        public static let INT = Signal(rawValue: SIGINT)
        public static let USR1 = Signal(rawValue: SIGUSR1)
        public static let USR2 = Signal(rawValue: SIGUSR2)
        public static let HUP = Signal(rawValue: SIGHUP)

        // for testing
        internal static let ALRM = Signal(rawValue: SIGALRM)

        public var description: String {
            var result = "Signal("
            switch self {
            case Signal.TERM: result += "TERM, "
            case Signal.INT: result += "INT, "
            case Signal.ALRM: result += "ALRM, "
            case Signal.USR1: result += "USR1, "
            case Signal.USR2: result += "USR2, "
            case Signal.HUP: result += "HUP, "
            default: () // ok to ignore
            }
            result += "rawValue: \(self.rawValue))"
            return result
        }
    }
}

extension ServiceLifecycle: LifecycleTasksContainer {
    @discardableResult
    public func register(_ tasks: [LifecycleTask]) -> [RegistrationKey] {
        return self.underlying.register(tasks)
    }

    public func deregister(_ key: RegistrationKey) {
        self.underlying.deregister(key)
    }
}

extension ServiceLifecycle {
    /// `ServiceLifecycle` configuration options.
    public struct Configuration {
        /// Defines the `label` for the lifeycle and its Logger
        public var label: String
        /// Defines the `Logger` to log with.
        public var logger: Logger
        /// Defines the `DispatchQueue` on which startup and shutdown callback handlers are run.
        public var callbackQueue: DispatchQueue
        /// Defines what, if any, signals to trap for invoking shutdown.
        public var shutdownSignal: [Signal]?
        /// Defines if to install a crash signal trap that prints backtraces.
        public var installBacktrace: Bool

        public init(label: String = "Lifecycle",
                    logger: Logger? = nil,
                    callbackQueue: DispatchQueue = .global(),
                    shutdownSignal: [Signal]? = [.TERM, .INT],
                    installBacktrace: Bool = true) {
            self.label = label
            self.logger = logger ?? Logger(label: label)
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

/// `ComponentLifecycle` provides a basic mechanism to cleanly startup and shutdown a subsystem in a larger application, freeing resources in order before exiting.
public class ComponentLifecycle: LifecycleTask {
    public let label: String
    fileprivate let logger: Logger
    fileprivate let shutdownGroup = DispatchGroup()

    private var state = State.idle(Registry())
    private let stateLock = Lock()

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

    /// Starts the provided `LifecycleTask` array.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    public func start(_ callback: @escaping (Error?) -> Void) {
        self.start(on: .global(), callback)
    }

    /// Starts the provided `LifecycleTask` array.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - on: `DispatchQueue` to run the handlers callback  on
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    public func start(on queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        guard case .idle(let registry) = (self.stateLock.withLock { self.state }) else {
            preconditionFailure("invalid state, \(self.state)")
        }
        self._start(on: queue, registry: registry, callback: callback)
    }

    /// Starts the provided `LifecycleTask` array and waits (blocking) until `shutdown` is called on another thread.
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

    /// Shuts down the `LifecycleTask` array provided in `start` or `startAndWait`.
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
        case .idle(let registry) where registry.isEmpty:
            self.state = .shutdown(nil)
            self.stateLock.unlock()
            defer { self.shutdownGroup.leave() }
            callback(nil)
        case .idle(let registry):
            self.stateLock.unlock()
            // attempt to shutdown any registered tasks
            let stoppable = registry.tasks.filter { $0.shutdownIfNotStarted }
            setupShutdownListener(.global())
            self._shutdown(on: .global(), tasks: stoppable, callback: self.shutdownGroup.leave)
        case .shutdown:
            self.stateLock.unlock()
            self.logger.warning("already shutdown")
            callback(nil)
        case .starting(let queue):
            self.state = .shuttingDown(queue)
            self.stateLock.unlock()
            setupShutdownListener(queue)
        case .shuttingDown(let queue):
            self.stateLock.unlock()
            setupShutdownListener(queue)
        case .started(let queue, let registry):
            self.stateLock.unlock()
            setupShutdownListener(queue)
            self._shutdown(on: queue, tasks: registry.tasks, callback: self.shutdownGroup.leave)
        }
    }

    /// Waits (blocking) until `shutdown` is invoked on another thread.
    public func wait() {
        self.shutdownGroup.wait()
    }

    // MARK: - internal

    internal var idle: Bool {
        if case .idle = self.state {
            return true
        } else {
            return false
        }
    }

    // MARK: - private

    private func _start(on queue: DispatchQueue, registry: Registry, callback: @escaping (Error?) -> Void) {
        self.stateLock.withLock {
            guard case .idle = self.state else {
                preconditionFailure("invalid state, \(self.state)")
            }
            self.state = .starting(queue)
        }

        self.logger.info("starting")
        Counter(label: "\(self.label).lifecycle.start").increment()

        if registry.isEmpty {
            self.logger.notice("no tasks provided")
        }
        self.startTask(on: queue, tasks: registry.tasks, index: 0) { started, error in
            self.stateLock.lock()
            if error != nil {
                self.state = .shuttingDown(queue)
            }
            switch self.state {
            case .shuttingDown:
                self.stateLock.unlock()
                // shutdown was called while starting, or start failed, shutdown what we can
                var stoppable = started
                if started.count < registry.tasks.count {
                    let shutdownIfNotStarted = registry.tasks.enumerated()
                        .filter { $0.offset >= started.count }
                        .map { $0.element }
                        .filter { $0.shutdownIfNotStarted }
                    stoppable.append(contentsOf: shutdownIfNotStarted)
                }
                self._shutdown(on: queue, tasks: stoppable) {
                    callback(error)
                    self.shutdownGroup.leave()
                }
            case .starting:
                self.state = .started(queue, registry)
                self.stateLock.unlock()
                callback(nil)
            default:
                preconditionFailure("invalid state, \(self.state)")
            }
        }
    }

    private func startTask(on queue: DispatchQueue, tasks: [LifecycleTask], index: Int, callback: @escaping ([LifecycleTask], Error?) -> Void) {
        // async barrier
        let start = { callback in queue.async { tasks[index].start(callback) } }
        let callback = { index, error in queue.async { callback(index, error) } }

        if index >= tasks.count {
            return callback(tasks, nil)
        }
        if tasks[index].logStart {
            self.logger.info("starting tasks [\(tasks[index].label)]")
        }
        let startTime = DispatchTime.now()
        start { error in
            Timer(label: "\(self.label).\(tasks[index].label).lifecycle.start").recordNanoseconds(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds)
            if let error = error {
                self.logger.error("failed to start [\(tasks[index].label)]: \(error)")
                let started = Array(tasks.prefix(index))
                return callback(started, error)
            }
            // shutdown called while starting
            if case .shuttingDown = self.stateLock.withLock({ self.state }) {
                let started = index < tasks.count ? Array(tasks.prefix(index + 1)) : tasks
                return callback(started, nil)
            }
            self.startTask(on: queue, tasks: tasks, index: index + 1, callback: callback)
        }
    }

    private func _shutdown(on queue: DispatchQueue, tasks: [LifecycleTask], callback: @escaping () -> Void) {
        self.stateLock.withLock {
            self.state = .shuttingDown(queue)
        }

        self.logger.info("shutting down")
        Counter(label: "\(self.label).lifecycle.shutdown").increment()

        self.shutdownTask(on: queue, tasks: tasks.reversed(), index: 0, errors: nil) { errors in
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

    private func shutdownTask(on queue: DispatchQueue, tasks: [LifecycleTask], index: Int, errors: [String: Error]?, callback: @escaping ([String: Error]?) -> Void) {
        // async barrier
        let shutdown = { callback in queue.async { tasks[index].shutdown(callback) } }
        let callback = { errors in queue.async { callback(errors) } }

        if index >= tasks.count {
            return callback(errors)
        }

        if tasks[index].logShutdown {
            self.logger.info("stopping tasks [\(tasks[index].label)]")
        }
        let startTime = DispatchTime.now()
        shutdown { error in
            Timer(label: "\(self.label).\(tasks[index].label).lifecycle.shutdown").recordNanoseconds(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds)
            var errors = errors
            if let error = error {
                if errors == nil {
                    errors = [:]
                }
                errors![tasks[index].label] = error
                self.logger.error("failed to stop [\(tasks[index].label)]: \(error)")
            }
            self.shutdownTask(on: queue, tasks: tasks, index: index + 1, errors: errors, callback: callback)
        }
    }

    private enum State {
        case idle(Registry)
        case starting(DispatchQueue)
        case started(DispatchQueue, Registry)
        case shuttingDown(DispatchQueue)
        case shutdown([String: Error]?)
    }
}

extension ComponentLifecycle: LifecycleTasksContainer {
    @discardableResult
    public func register(_ newTasks: [LifecycleTask]) -> [RegistrationKey] {
        let registrationKeys = self.stateLock.withLock { () -> [RegistrationKey] in
            guard case .idle(let registry) = self.state else {
                preconditionFailure("invalid state, \(self.state)")
            }
            return registry.add(newTasks)
        }
        return registrationKeys
    }

    public func deregister(_ key: RegistrationKey) {
        func remove(key: RegistrationKey, tasks: [LifecycleTask], keys: [RegistrationKey]) -> ([LifecycleTask], [RegistrationKey]) {
            guard let index = keys.firstIndex(of: key) else {
                return (tasks, keys)
            }
            var updatedTasks = tasks
            updatedTasks.remove(at: index)
            var updatedKeys = keys
            updatedKeys.remove(at: index)
            return (updatedTasks, updatedKeys)
        }

        self.stateLock.withLock {
            switch self.state {
            case .idle(let registry), .started(_, let registry):
                registry.remove(key)
            default:
                preconditionFailure("invalid state, \(self.state)")
            }
        }
    }
}

/// A container of `LifecycleTask`, used to register additional `LifecycleTask`
public protocol LifecycleTasksContainer {
    typealias RegistrationKey = String

    /// Register a `LifecycleTask` with a `LifecycleTasksContainer`.
    ///
    /// - parameters:
    ///    - tasks: array of `LifecycleTask`.
    @discardableResult
    func register(_ tasks: [LifecycleTask]) -> [RegistrationKey]

    /// De-register a `LifecycleTask` from a `LifecycleTasksContainer`.
    ///
    /// - parameters:
    ///    - registrationKey: The key returned by a register operation.
    func deregister(_ key: RegistrationKey)
}

extension LifecycleTasksContainer {
    /// Register a `LifecycleTask` with a `LifecycleTasksContainer`.
    ///
    /// - parameters:
    ///    - tasks: one or more `LifecycleTask`.
    @discardableResult
    public func register(_ tasks: LifecycleTask ...) -> [RegistrationKey] {
        return self.register(tasks)
    }

    /// Register a `LifecycleTask` with a `LifecycleTasksContainer`.
    ///
    /// - parameters:
    ///    - tasks: one or more `LifecycleTask`.
    @discardableResult
    public func register(_ tasks: LifecycleTask) -> RegistrationKey {
        return self.register(tasks).first! // force the optional on the first in this case is safe
    }

    /// Register a `LifecycleTask` with a `LifecycleTasksContainer`.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - start: `Handler` to perform the startup.
    ///    - shutdown: `Handler` to perform the shutdown.
    @discardableResult
    public func register(label: String, start: LifecycleHandler, shutdown: LifecycleHandler, shutdownIfNotStarted: Bool? = nil) -> RegistrationKey {
        return self.register(_LifecycleTask(label: label, shutdownIfNotStarted: shutdownIfNotStarted, start: start, shutdown: shutdown))
    }

    /// Register a `LifecycleTask` with a `LifecycleTasksContainer`.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - handler: `Handler` to perform the shutdown.
    @discardableResult
    public func registerShutdown(label: String, _ handler: LifecycleHandler) -> RegistrationKey {
        return self.register(label: label, start: .none, shutdown: handler)
    }

    /// Register a stateful `LifecycleTask` with a `LifecycleTasksContainer`.
    ///
    /// - parameters:
    ///    - label: label of the item, useful for debugging.
    ///    - start: `LifecycleStartHandler` to perform the startup and return the state.
    ///    - shutdown: `LifecycleShutdownHandler` to perform the shutdown given the state.
    @discardableResult
    public func registerStateful<State>(label: String, start: LifecycleStartHandler<State>, shutdown: LifecycleShutdownHandler<State>) -> RegistrationKey {
        return self.register(StatefulLifecycleTask(label: label, start: start, shutdown: shutdown))
    }
}

// internal for testing
internal struct _LifecycleTask: LifecycleTask {
    let label: String
    let shutdownIfNotStarted: Bool
    let start: LifecycleHandler
    let shutdown: LifecycleHandler
    let logStart: Bool
    let logShutdown: Bool

    init(label: String, shutdownIfNotStarted: Bool? = nil, start: LifecycleHandler, shutdown: LifecycleHandler) {
        self.label = label
        self.shutdownIfNotStarted = shutdownIfNotStarted ?? start.noop
        self.start = start
        self.shutdown = shutdown
        self.logStart = !start.noop
        self.logShutdown = !shutdown.noop
    }

    func start(_ callback: @escaping (Error?) -> Void) {
        self.start.run(callback)
    }

    func shutdown(_ callback: @escaping (Error?) -> Void) {
        self.shutdown.run(callback)
    }
}

// internal (instead of private) for testing
internal class StatefulLifecycleTask<State>: LifecycleTask {
    let label: String
    let shutdownIfNotStarted: Bool = false
    let start: LifecycleStartHandler<State>
    let shutdown: LifecycleShutdownHandler<State>

    let stateLock = Lock()
    var state: State?

    init(label: String, start: LifecycleStartHandler<State>, shutdown: LifecycleShutdownHandler<State>) {
        self.label = label
        self.start = start
        self.shutdown = shutdown
    }

    func start(_ callback: @escaping (Error?) -> Void) {
        self.start.run { result in
            switch result {
            case .failure(let error):
                callback(error)
            case .success(let state):
                self.stateLock.withLock {
                    self.state = state
                }
                callback(nil)
            }
        }
    }

    func shutdown(_ callback: @escaping (Error?) -> Void) {
        guard let state = (self.stateLock.withLock { self.state }) else {
            return callback(UnknownState())
        }
        self.shutdown.run(state: state, callback)
    }

    struct UnknownState: Error {}
}

private class Registry {
    typealias RegistrationKey = LifecycleTasksContainer.RegistrationKey

    private var _tasks: [LifecycleTask] = []
    private var keys: [LifecycleTasksContainer.RegistrationKey] = []
    private let lock = Lock()

    func add(_ tasks: [LifecycleTask]) -> [RegistrationKey] {
        // FIXME: better id generation scheme (cant use UUID)
        let keys: [RegistrationKey] = tasks.map { _ in
            let random = UInt64.random(in: UInt64.min ..< UInt64.max).addingReportingOverflow(DispatchTime.now().uptimeNanoseconds).partialValue
            return "task-\(random)"
        }
        self.lock.withLock {
            self._tasks.append(contentsOf: tasks)
            self.keys.append(contentsOf: keys)
        }
        return keys
    }

    func remove(_ key: RegistrationKey) {
        self.lock.withLock {
            guard let index = self.keys.firstIndex(of: key) else {
                return
            }
            self._tasks.remove(at: index)
            self.keys.remove(at: index)
        }
    }

    var tasks: [LifecycleTask] {
        return self.lock.withLock { self._tasks }
    }

    var isEmpty: Bool {
        return self.lock.withLock { self._tasks.isEmpty }
    }
}
