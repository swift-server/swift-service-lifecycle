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

import AsyncAlgorithms

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AsyncSequence where Self: Sendable, Element: Sendable {
    /// Creates an asynchronous sequence that is cancelled once graceful shutdown has triggered.
    ///
    /// Use this in places where the only logical thing on graceful shutdown is to cancel your iteration.
    public func cancelOnGracefulShutdown() -> AsyncCancelOnGracefulShutdownSequence<Self> {
        AsyncCancelOnGracefulShutdownSequence(base: self)
    }
}

/// An asynchronous sequence that is cancelled after graceful shutdown has triggered.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct AsyncCancelOnGracefulShutdownSequence<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable
where Base.Element: Sendable {
    @usableFromInline
    enum _ElementOrGracefulShutdown: Sendable {
        case base(AsyncMapNilSequence<Base>.Element)
        case gracefulShutdown
    }

    @usableFromInline
    typealias Merged = AsyncMerge2Sequence<
        AsyncMapSequence<AsyncMapNilSequence<Base>, _ElementOrGracefulShutdown>,
        AsyncMapSequence<AsyncMapNilSequence<AsyncGracefulShutdownSequence>, _ElementOrGracefulShutdown>
    >

    /// The type that the sequence produces.
    public typealias Element = Base.Element

    @usableFromInline
    let _merge: Merged

    /// Creates a new asynchronous sequence that cancels after graceful shutdown is triggered.
    /// - Parameter base: The asynchronous sequence to wrap.
    @inlinable
    public init(base: Base) {
        self._merge = merge(
            base.mapNil().map { .base($0) },
            AsyncGracefulShutdownSequence().mapNil().map { _ in .gracefulShutdown }
        )
    }

    /// Creates an iterator for the sequence.
    @inlinable
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: self._merge.makeAsyncIterator())
    }

    /// An iterator for an asynchronous sequence that cancels after graceful shutdown is triggered.
    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        var _iterator: Merged.AsyncIterator

        @usableFromInline
        var _isFinished = false

        @inlinable
        init(iterator: Merged.AsyncIterator) {
            self._iterator = iterator
        }

        /// Returns the next item in the sequence, or `nil` if the sequence is finished.
        @inlinable
        public mutating func next() async rethrows -> Element? {
            guard !self._isFinished else {
                return nil
            }

            let value = try await self._iterator.next()

            switch value {
            case .base(let element):

                switch element {
                case .element(let element):
                    return element

                case .end:
                    self._isFinished = true
                    return nil
                }

            case .gracefulShutdown:
                return nil

            case .none:
                return nil
            }
        }
    }
}

/// This is just a helper extension and sequence to allow us to get the `nil` value as an element of the sequence.
/// We need this since merge is only finishing when both upstreams are finished but we need to finish when either is done.
/// In the future, we should move to something in async algorithms if it exists.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AsyncSequence where Self: Sendable, Element: Sendable {
    @inlinable
    func mapNil() -> AsyncMapNilSequence<Self> {
        AsyncMapNilSequence(base: self)
    }
}

@usableFromInline
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
struct AsyncMapNilSequence<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable where Base.Element: Sendable {
    @usableFromInline
    enum ElementOrEnd: Sendable {
        case element(Base.Element)
        case end
    }

    @usableFromInline
    typealias Element = ElementOrEnd

    @usableFromInline
    let _base: Base

    @inlinable
    init(base: Base) {
        self._base = base
    }

    @inlinable
    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: self._base.makeAsyncIterator())
    }

    @usableFromInline
    struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        var _iterator: Base.AsyncIterator

        @usableFromInline
        var _hasSeenEnd = false

        @inlinable
        init(iterator: Base.AsyncIterator) {
            self._iterator = iterator
        }

        @inlinable
        mutating func next() async rethrows -> Element? {
            let value = try await self._iterator.next()

            if let value {
                return .element(value)
            } else if self._hasSeenEnd {
                return nil
            } else {
                self._hasSeenEnd = true
                return .end
            }
        }
    }
}
