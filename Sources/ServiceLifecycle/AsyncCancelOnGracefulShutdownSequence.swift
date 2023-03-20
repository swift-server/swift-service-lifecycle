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

extension AsyncSequence where Self: Sendable, Element: Sendable {
    /// Creates an asynchronous sequence that is cancelled once graceful shutdown has triggered.
    public func cancelOnGracefulShutdown() -> AsyncCancelOnGracefulShutdownSequence<Self> {
        AsyncCancelOnGracefulShutdownSequence(base: self)
    }
}

public struct AsyncCancelOnGracefulShutdownSequence<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable where Base.Element: Sendable {
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

    public typealias Element = Base.Element

    @usableFromInline
    let _merge: Merged

    @inlinable
    public init(base: Base) {
        self._merge = .init(
            base.mapNil().map { .base($0) },
            AsyncGracefulShutdownSequence().mapNil().map { _ in .gracefulShutdown }
        )
    }

    @inlinable
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: self._merge.makeAsyncIterator())
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        var _iterator: Merged.AsyncIterator

        @usableFromInline
        var _isFinished = false

        @inlinable
        init(iterator: Merged.AsyncIterator) {
            self._iterator = iterator
        }

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

extension AsyncSequence where Self: Sendable, Element: Sendable {
    @inlinable
    func mapNil() -> AsyncMapNilSequence<Self> {
        AsyncMapNilSequence(base: self)
    }
}

@usableFromInline
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
