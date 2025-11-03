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

#if canImport(Darwin)
import Darwin
import Dispatch
#else
@preconcurrency import Dispatch
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif
import ConcurrencyHelpers

/// An unterminated `AsyncSequence` of ``UnixSignal``s.
///
/// This can be used to setup signal handlers and receive the signals on the sequence.
///
/// - Important: There can only be a single signal handler for a signal installed. So you should avoid creating multiple handlers
/// for the same signal.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct UnixSignalsSequence: AsyncSequence, Sendable {
    private static let queue = DispatchQueue(label: "com.service-lifecycle.unix-signals")

    public typealias Element = UnixSignal

    fileprivate struct Source: Sendable {
        var dispatchSource: DispatchSource
        var signal: UnixSignal
    }

    private let storage: Storage

    public init(trapping signals: UnixSignal...) async {
        await self.init(trapping: signals)
    }

    public init(trapping signals: [UnixSignal]) async {
        // We are converting the signals to a Set here to remove duplicates
        self.storage = await .init(signals: Set(signals))
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return .init(iterator: self.storage.makeAsyncIterator(), storage: self.storage)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private var iterator: AsyncStream<UnixSignal>.Iterator
        // We need to keep the underlying `DispatchSourceSignal` alive to receive notifications.
        private let storage: Storage

        fileprivate init(iterator: AsyncStream<UnixSignal>.Iterator, storage: Storage) {
            self.iterator = iterator
            self.storage = storage
        }

        public mutating func next() async -> UnixSignal? {
            return await self.iterator.next()
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension UnixSignalsSequence {
    fileprivate final class Storage: @unchecked Sendable {
        private let stateMachine: LockedValueBox<StateMachine>

        init(signals: Set<UnixSignal>) async {
            #if !os(Windows)
            let sources: [Source] = signals.compactMap { sig -> Source? in
                #if canImport(Darwin)
                // On Darwin platforms Dispatch's signal source uses kqueue and EVFILT_SIGNAL for
                // delivering signals. This exists alongside but with lower precedence than signal and
                // sigaction: ignore signal handling here to kqueue can deliver signals.
                signal(sig.rawValue, SIG_IGN)
                #endif
                return .init(
                    // This force-unwrap is safe since Dispatch always returns a `DispatchSource`
                    dispatchSource: DispatchSource.makeSignalSource(
                        signal: sig.rawValue,
                        queue: UnixSignalsSequence.queue
                    ) as! DispatchSource,
                    signal: sig
                )
            }

            let stream = AsyncStream<UnixSignal> { continuation in
                for source in sources {
                    source.dispatchSource.setEventHandler {
                        continuation.yield(source.signal)
                    }
                    source.dispatchSource.setCancelHandler {
                        continuation.finish()
                    }
                }

                // Don't wait forever if there's nothing to wait for.
                if sources.isEmpty {
                    continuation.finish()
                }
            }

            self.stateMachine = .init(.init(sources: sources, stream: stream))

            // Registering sources is async: await their registration so we don't miss early signals.
            await withTaskCancellationHandler {
                for source in sources {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let action = self.stateMachine.withLockedValue {
                            $0.registeringSignal(continuation: continuation)
                        }
                        switch action {
                        case .setRegistrationHandlerAndResumeDispatchSource:
                            source.dispatchSource.setRegistrationHandler {
                                let action = self.stateMachine.withLockedValue { $0.registeredSignal() }

                                switch action {
                                case .none:
                                    break

                                case .resumeContinuation(let continuation):
                                    continuation.resume()
                                }
                            }
                            source.dispatchSource.resume()

                        case .resumeContinuation(let continuation):
                            continuation.resume()
                        }
                    }
                }
            } onCancel: {
                let action = self.stateMachine.withLockedValue { $0.cancelledInit() }

                switch action {
                case .none:
                    break

                case .cancelAllSources:
                    for source in sources {
                        source.dispatchSource.cancel()
                    }

                case .resumeContinuationAndCancelAllSources(let continuation):
                    continuation.resume()

                    for source in sources {
                        source.dispatchSource.cancel()
                    }
                }
            }
            #else
            let stream = AsyncStream<UnixSignal> { _ in }
            self.stateMachine = .init(.init(sources: [], stream: stream))
            #endif
        }

        func makeAsyncIterator() -> AsyncStream<UnixSignal>.AsyncIterator {
            return self.stateMachine.withLockedValue { $0.makeAsyncIterator() }
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension UnixSignalsSequence {
    fileprivate struct StateMachine {
        private enum State {
            /// The initial state.
            case canRegisterSignal(
                sources: [Source],
                stream: AsyncStream<UnixSignal>
            )
            /// The state once we started to register a signal handler.
            ///
            /// - Note: We can enter this state multiple times. One for each signal handler.
            case registeringSignal(
                sources: [Source],
                stream: AsyncStream<UnixSignal>,
                continuation: CheckedContinuation<Void, Never>
            )
            /// The state once an iterator has been created.
            case producing(
                sources: [Source],
                stream: AsyncStream<UnixSignal>
            )
            /// The state when the task that creates the UnixSignals gets cancelled during init.
            case cancelled(
                stream: AsyncStream<UnixSignal>
            )
        }

        private var state: State

        init(sources: [Source], stream: AsyncStream<UnixSignal>) {
            self.state = .canRegisterSignal(sources: sources, stream: stream)
        }

        enum RegisteringSignalAction {
            case setRegistrationHandlerAndResumeDispatchSource
            case resumeContinuation(CheckedContinuation<Void, Never>)
        }

        mutating func registeringSignal(continuation: CheckedContinuation<Void, Never>) -> RegisteringSignalAction {
            switch self.state {
            case .canRegisterSignal(let sources, let stream):
                self.state = .registeringSignal(sources: sources, stream: stream, continuation: continuation)

                return .setRegistrationHandlerAndResumeDispatchSource

            case .registeringSignal:
                fatalError("UnixSignals tried to register multiple signals at once")

            case .producing:
                fatalError("UnixSignals tried to create an iterator before the init was done")

            case .cancelled:
                return .resumeContinuation(continuation)
            }
        }

        enum RegisteredSignalAction {
            case resumeContinuation(CheckedContinuation<Void, Never>)
        }

        mutating func registeredSignal() -> RegisteredSignalAction? {
            switch self.state {
            case .canRegisterSignal:
                fatalError("UnixSignals tried to register signals more than once")

            case .registeringSignal(let sources, let stream, let continuation):
                self.state = .canRegisterSignal(sources: sources, stream: stream)

                return .resumeContinuation(continuation)

            case .producing:
                fatalError("UnixSignals tried to create an iterator before the init was done")

            case .cancelled:
                // This is okay. The registration and cancelling the source might race.
                return .none
            }
        }

        enum CancelledInitAction {
            case cancelAllSources
            case resumeContinuationAndCancelAllSources(CheckedContinuation<Void, Never>)
        }

        mutating func cancelledInit() -> CancelledInitAction? {
            switch self.state {
            case .canRegisterSignal(_, let stream):
                self.state = .cancelled(stream: stream)

                return .cancelAllSources

            case .registeringSignal(_, let stream, let continuation):
                self.state = .cancelled(stream: stream)

                return .resumeContinuationAndCancelAllSources(continuation)

            case .producing:
                // This is a weird one. The task that created the UnixSignals
                // got cancelled but we already made an iterator. I guess
                // this can happen while we are racing so let's just tolerate that
                // and do nothing. If the task that created the UnixSignals and is
                // consuming it is the same one then the stream will terminate anyhow.
                return .none

            case .cancelled:
                fatalError("UnixSignals registration cancelled more than once")
            }
        }

        mutating func makeAsyncIterator() -> AsyncStream<UnixSignal>.AsyncIterator {
            switch self.state {
            case .canRegisterSignal(let sources, let stream):
                // This can happen when we created a UnixSignal without any signals
                self.state = .producing(sources: sources, stream: stream)

                return stream.makeAsyncIterator()

            case .registeringSignal:
                fatalError("UnixSignals tried to create iterator before all handlers were installed")

            case .producing:
                fatalError("UnixSignals only allows a single iterator to be created")

            case .cancelled(let stream):
                return stream.makeAsyncIterator()
            }
        }
    }
}
