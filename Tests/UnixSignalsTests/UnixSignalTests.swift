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

#if !os(Windows)

@testable import UnixSignals
import Dispatch
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// Holds a dispatch source weakly so that a test can observe it being released.
///
/// This is `@unchecked Sendable` because the source can be released on the dispatch queue rather
/// than on the thread that dropped the last reference. Swift's weak loads and stores are
/// themselves thread safe and awaiting the task orders the hand-off against our reads.
private final class WeakDispatchSource: @unchecked Sendable {
    weak var value: DispatchSource?

    init(_ value: DispatchSource) {
        self.value = value
    }
}

final class UnixSignalTests: XCTestCase {
    @available(*, deprecated, message: "Tests the deprecated UnixSignalsSequence initializers.")
    func testSingleSignal() async throws {
        let signal = UnixSignal.sigalrm
        let signals = await UnixSignalsSequence(trapping: signal)
        let pid = getpid()

        var signalIterator = signals.makeAsyncIterator()
        kill(pid, signal.rawValue)  // ignore-unacceptable-language
        let caught = await signalIterator.next()
        XCTAssertEqual(caught, signal)
    }

    @available(*, deprecated, message: "Tests the deprecated UnixSignalsSequence initializers.")
    func testCatchingMultipleSignals() async throws {
        let signal = UnixSignal.sigalrm
        let signals = await UnixSignalsSequence(trapping: signal)
        let pid = getpid()

        var signalIterator = signals.makeAsyncIterator()
        for _ in 0..<5 {
            kill(pid, signal.rawValue)  // ignore-unacceptable-language

            let caught = await signalIterator.next()
            XCTAssertEqual(caught, signal)
        }
    }

    @available(*, deprecated, message: "Tests the deprecated UnixSignalsSequence initializers.")
    func testCancelOnSignal() async throws {
        enum GroupResult {
            case timedOut
            case cancelled
            case caughtSignal
        }

        try await withThrowingTaskGroup(of: GroupResult.self) { group in
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return .timedOut
                } catch {
                    XCTAssert(error is CancellationError)
                    return .cancelled
                }
            }

            group.addTask {
                for await _ in await UnixSignalsSequence(trapping: .sigalrm) {
                    return .caughtSignal
                }
                fatalError()
            }

            // Allow 10ms for the tasks to start.
            try await Task.sleep(nanoseconds: 10_000_000)
            let pid = getpid()
            kill(pid, UnixSignal.sigalrm.rawValue)  // ignore-unacceptable-language

            let first = try await group.next()
            XCTAssertEqual(first, .caughtSignal)

            // Caught the signal; cancel the remaining task.
            group.cancelAll()
            let second = try await group.next()
            XCTAssertEqual(second, .cancelled)
        }
    }

    @available(*, deprecated, message: "Tests the deprecated UnixSignalsSequence initializers.")
    func testDispatchSourcesAreCancelledWhenSequenceIsReleased() async throws {
        var signals: UnixSignalsSequence? = await UnixSignalsSequence(trapping: .sighup)
        let sources = signals!.dispatchSources
        XCTAssertFalse(sources.isEmpty)
        XCTAssertFalse(sources.contains { $0.isCancelled })

        signals = nil

        // Dropping the sequence does not necessarily drop the last reference to the storage:
        // libdispatch's registration handler holds one as well and only releases it on the
        // dispatch queue after it has resumed us, so the deinit can still be pending here.
        for _ in 0..<100 where !sources.allSatisfy({ $0.isCancelled }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(sources.allSatisfy { $0.isCancelled })
    }

    @available(*, deprecated, message: "Tests the deprecated UnixSignalsSequence initializers.")
    func testDispatchSourcesAreReleasedWhenInitIsCancelled() async throws {
        let task = Task { () -> [WeakDispatchSource] in
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            XCTAssertTrue(Task.isCancelled)

            let signals = await UnixSignalsSequence(trapping: .sighup)
            return signals.dispatchSources.map(WeakDispatchSource.init)
        }

        // Only weak references survive the task, so the sources are released as soon as nothing
        // else holds on to them.
        let sources = await task.value
        XCTAssertFalse(sources.isEmpty)

        for _ in 0..<100 where sources.contains(where: { $0.value != nil }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(sources.allSatisfy { $0.value == nil })
    }

    @available(*, deprecated, message: "Tests the deprecated UnixSignalsSequence initializers.")
    func testEmptySequence() async throws {
        let signals = await UnixSignalsSequence(trapping: [])
        for await _ in signals {
            XCTFail("Unexpected siganl")
        }
    }

    @available(*, deprecated, message: "Tests the deprecated UnixSignalsSequence initializers.")
    func testCorrectSignalIsGiven() async throws {
        let signals = await UnixSignalsSequence(trapping: .sigterm, .sigusr1, .sigusr2, .sighup, .sigint, .sigalrm)
        var signalIterator = signals.makeAsyncIterator()

        let signal = UnixSignal.sigalrm
        let pid = getpid()

        for _ in 0..<10 {
            kill(pid, signal.rawValue)  // ignore-unacceptable-language
            let trapped = await signalIterator.next()
            XCTAssertEqual(trapped, signal)
        }
    }

    func testWithUnixSignalsDeliversSignal() async throws {
        let signal = UnixSignal.sigalrm
        let caught = await withUnixSignals([signal]) { signals in
            var signalIterator = signals.makeAsyncIterator()
            kill(getpid(), signal.rawValue)  // ignore-unacceptable-language
            return await signalIterator.next()
        }
        XCTAssertEqual(caught, signal)
    }

    func testWithUnixSignalsCancelsSourcesWhenBodyReturns() async throws {
        let signals = await withUnixSignals([.sighup]) { signals in
            XCTAssertFalse(signals.dispatchSources.isEmpty)
            XCTAssertFalse(signals.dispatchSources.contains { $0.isCancelled })
            return signals
        }

        XCTAssertTrue(signals.dispatchSources.allSatisfy { $0.isCancelled })
    }

    func testWithUnixSignalsCancelsSourcesWhenBodyThrows() async throws {
        struct TestError: Error {}
        var escaped: UnixSignalsSequence?

        do {
            try await withUnixSignals([.sighup]) { signals in
                escaped = signals
                throw TestError()
            }
            XCTFail("Expected an error")
        } catch {
            XCTAssert(error is TestError)
        }

        let signals = try XCTUnwrap(escaped)
        XCTAssertFalse(signals.dispatchSources.isEmpty)
        XCTAssertTrue(signals.dispatchSources.allSatisfy { $0.isCancelled })
    }

    func testWithUnixSignalsCancelsSourcesWhenTaskIsCancelled() async throws {
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            await withUnixSignals([.sighup]) { signals in
                startedContinuation.yield()
                for await _ in signals {}
                return signals
            }
        }

        await started.first { _ in true }
        task.cancel()

        let signals = await task.value
        XCTAssertFalse(signals.dispatchSources.isEmpty)
        XCTAssertTrue(signals.dispatchSources.allSatisfy { $0.isCancelled })
    }

    func testSignalRawValue() {
        func assert(_ signal: UnixSignal, rawValue: Int32) {
            XCTAssertEqual(signal.rawValue, rawValue)
        }

        assert(.sigalrm, rawValue: SIGALRM)
        assert(.sigint, rawValue: SIGINT)
        assert(.sigquit, rawValue: SIGQUIT)
        assert(.sighup, rawValue: SIGHUP)
        assert(.sigusr1, rawValue: SIGUSR1)
        assert(.sigusr2, rawValue: SIGUSR2)
        assert(.sigterm, rawValue: SIGTERM)
    }

    func testSignalCustomStringConvertible() {
        func assert(_ signal: UnixSignal, description: String) {
            XCTAssertEqual(String(describing: signal), description)
        }

        assert(.sigalrm, description: "SIGALRM")
        assert(.sigint, description: "SIGINT")
        assert(.sigquit, description: "SIGQUIT")
        assert(.sighup, description: "SIGHUP")
        assert(.sigusr1, description: "SIGUSR1")
        assert(.sigusr2, description: "SIGUSR2")
        assert(.sigterm, description: "SIGTERM")
        assert(.sigwinch, description: "SIGWINCH")
    }

    @available(*, deprecated, message: "Tests the deprecated UnixSignalsSequence initializers.")
    func testCancelledTask() async throws {
        let task = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            let UnixSignalsSequence = await UnixSignalsSequence(trapping: .sigterm)

            for await _ in UnixSignalsSequence {}
        }

        task.cancel()

        await task.value
    }
}

#endif
