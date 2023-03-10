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
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch

public struct UnixSignal: Hashable, Sendable, CustomStringConvertible {
    internal enum Wrapped {
        case sighup
        case sigint
        case sigterm
        case sigusr1
        case sigusr2
        case sigalrm
    }

    private let wrapped: Wrapped
    private init(_ wrapped: Wrapped) {
        self.wrapped = wrapped
    }

    public var rawValue: Int32 {
        return self.wrapped.rawValue
    }

    public var description: String {
        return String(describing: self.wrapped)
    }

    public static let sighup = Self(.sighup)
    public static let sigint = Self(.sigint)
    public static let sigterm = Self(.sigterm)
    public static let sigusr1 = Self(.sigusr1)
    public static let sigusr2 = Self(.sigusr2)
    public static let sigalrm = Self(.sigalrm)
}

extension UnixSignal.Wrapped: Hashable {}
extension UnixSignal.Wrapped: Sendable {}

extension UnixSignal.Wrapped: CustomStringConvertible {
    var description: String {
        switch self {
        case .sighup:
            return "SIGHUP"
        case .sigint:
            return "SIGINT"
        case .sigterm:
            return "SIGTERM"
        case .sigusr1:
            return "SIGUSR1"
        case .sigusr2:
            return "SIGUSR2"
        case .sigalrm:
            return "SIGALRM"
        }
    }
}

extension UnixSignal.Wrapped {
    var rawValue: Int32 {
        switch self {
        case .sighup:
            return SIGHUP
        case .sigint:
            return SIGINT
        case .sigterm:
            return SIGTERM
        case .sigusr1:
            return SIGUSR1
        case .sigusr2:
            return SIGUSR2
        case .sigalrm:
            return SIGALRM
        }
    }
}
