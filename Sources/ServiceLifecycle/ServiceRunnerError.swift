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

/// Errors thrown by the ``ServiceRunner``.
public struct ServiceRunnerError: Error, Hashable, Sendable {
    /// A struct representing the possible error codes.
    public struct ErrorCode: Hashable, Sendable, CustomStringConvertible {
        private enum _ErrorCode: Hashable, Sendable {
            case alreadyRunning
            case alreadyFinished
            case serviceFinishedUnexpectedly
        }

        private var errorCode: _ErrorCode

        private init(errorCode: _ErrorCode) {
            self.errorCode = errorCode
        }

        public var description: String {
            switch self.errorCode {
            case .alreadyRunning:
                return "The service runner is already running the services."
            case .alreadyFinished:
                return "The service runner has already finished running the services."
            case .serviceFinishedUnexpectedly:
                return "A service has finished unexpectedly."
            }
        }

        /// Indicates that the service runner is already running.
        public static let alreadyRunning = ErrorCode(errorCode: .alreadyRunning)
        /// Indicates that the service runner has already finished running.
        public static let alreadyFinished = ErrorCode(errorCode: .alreadyFinished)
        /// Indicates that a service finished unexpectedly even though it indicated it is a long running service.
        public static let serviceFinishedUnexpectedly = ErrorCode(errorCode: .serviceFinishedUnexpectedly)
    }

    /// Internal class that contains the actual error code.
    private final class Backing: Hashable, Sendable, CustomStringConvertible {
        let errorCode: ErrorCode
        let file: String
        let line: Int

        init(errorCode: ErrorCode, file: String, line: Int) {
            self.errorCode = errorCode
            self.file = file
            self.line = line
        }

        static func == (lhs: Backing, rhs: Backing) -> Bool {
            lhs.errorCode == rhs.errorCode
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(self.errorCode)
        }

        var description: String {
            "errorCode: \(self.errorCode), file: \(self.file), line: \(self.line)"
        }
    }

    /// The backing storage of the error.
    private let backing: Backing

    /// The error code.
    ///
    /// - Note: This is the only thing used for the `Equatable` and `Hashable` comparison.
    public var errorCode: ErrorCode {
        self.backing.errorCode
    }

    private init(_ backing: Backing) {
        self.backing = backing
    }

    /// Indicates that the service runner is already running.
    public static func alreadyRunning(file: String = #fileID, line: Int = #line) -> Self {
        Self(
            .init(
                errorCode: .alreadyRunning,
                file: file,
                line: line
            )
        )
    }

    /// Indicates that the service runner has already finished running.
    public static func alreadyFinished(file: String = #fileID, line: Int = #line) -> Self {
        Self(
            .init(
                errorCode: .alreadyRunning,
                file: file,
                line: line
            )
        )
    }

    /// Indicates that a service finished unexpectedly even though it indicated it is a long running service.
    public static func serviceFinishedUnexpectedly(file: String = #fileID, line: Int = #line) -> Self {
        Self(
            .init(
                errorCode: .serviceFinishedUnexpectedly,
                file: file,
                line: line
            )
        )
    }
}

extension ServiceRunnerError: CustomStringConvertible {
    public var description: String {
        "ServiceRunnerError: \(self.backing)"
    }
}
