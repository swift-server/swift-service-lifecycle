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

/// Errors thrown by a service group.
public struct ServiceGroupError: Error, Hashable, Sendable {
    /// A struct that represents the possible error codes.
    public struct Code: Hashable, Sendable, CustomStringConvertible {
        private enum _Code: Hashable, Sendable {
            case alreadyRunning
            case alreadyFinished
            case serviceFinishedUnexpectedly
        }

        private var code: _Code

        private init(code: _Code) {
            self.code = code
        }

        /// A string representation of a service group error.
        public var description: String {
            switch self.code {
            case .alreadyRunning:
                return "The service group is already running the services."
            case .alreadyFinished:
                return "The service group has already finished running the services."
            case .serviceFinishedUnexpectedly:
                return "A service has finished unexpectedly."
            }
        }

        /// Indicates that the service group is already running.
        public static let alreadyRunning = Code(code: .alreadyRunning)
        /// Indicates that the service group has already finished running.
        public static let alreadyFinished = Code(code: .alreadyFinished)
        /// Indicates that a service finished unexpectedly.
        public static let serviceFinishedUnexpectedly = Code(code: .serviceFinishedUnexpectedly)
    }

    /// Internal class that contains the actual error code.
    private final class Backing: Hashable, Sendable {
        let message: String?
        let errorCode: Code
        let file: String
        let line: Int

        init(errorCode: Code, file: String, line: Int, message: String?) {
            self.errorCode = errorCode
            self.file = file
            self.line = line
            self.message = message
        }

        static func == (lhs: Backing, rhs: Backing) -> Bool {
            lhs.errorCode == rhs.errorCode
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(self.errorCode)
        }
    }

    /// The backing storage of the error.
    private let backing: Backing

    /// The error code.
    ///
    /// - Note: This is the only thing used for the `Equatable` and `Hashable` comparisons for instances of `ServiceGroupError`.
    public var errorCode: Code {
        self.backing.errorCode
    }

    private init(_ backing: Backing) {
        self.backing = backing
    }

    /// Indicates that the service group is already running.
    public static func alreadyRunning(file: String = #fileID, line: Int = #line) -> Self {
        Self(
            .init(
                errorCode: .alreadyRunning,
                file: file,
                line: line,
                message: ""
            )
        )
    }

    /// Indicates that the service group has already finished running.
    public static func alreadyFinished(file: String = #fileID, line: Int = #line) -> Self {
        Self(
            .init(
                errorCode: .alreadyFinished,
                file: file,
                line: line,
                message: ""
            )
        )
    }

    /// Indicates that a service finished unexpectedly even though it indicated it is a long running service.
    public static func serviceFinishedUnexpectedly(
        file: String = #fileID,
        line: Int = #line,
        service: String? = nil
    ) -> Self {
        Self(
            .init(
                errorCode: .serviceFinishedUnexpectedly,
                file: file,
                line: line,
                message: service.flatMap { "Service failed(\($0))" }
            )
        )
    }
}

extension ServiceGroupError: CustomStringConvertible {
    /// A string representation of the service group error.
    public var description: String {
        "ServiceGroupError: errorCode: \(self.backing.errorCode), file: \(self.backing.file), line: \(self.backing.line) \(self.backing.message.flatMap { ", message: \($0)" } ?? "")"
    }
}
