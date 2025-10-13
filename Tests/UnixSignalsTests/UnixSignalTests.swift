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

import UnixSignals
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

final class UnixSignalTests: XCTestCase {
    func testSingleSignal() async throws {
        let signal = UnixSignal.sigalrm
        let signals = await UnixSignalsSequence(trapping: signal)
        let pid = getpid()

        var signalIterator = signals.makeAsyncIterator()
        kill(pid, signal.rawValue)  // ignore-unacceptable-language
        let caught = await signalIterator.next()
        XCTAssertEqual(caught, signal)
    }

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

    func testEmptySequence() async throws {
        let signals = await UnixSignalsSequence(trapping: [])
        for await _ in signals {
            XCTFail("Unexpected siganl")
        }
    }

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
