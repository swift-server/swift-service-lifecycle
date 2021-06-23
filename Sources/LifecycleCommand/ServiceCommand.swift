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

@_exported import ArgumentParser
@_exported import Lifecycle

public protocol ServiceCommand: ParsableCommand {
    static var lifecycle: ServiceLifecycle { get }
    func bootstrap() throws
    func configure(_ lifecycle: ServiceLifecycle) throws
    func onStart(_ error: Error?)
}

extension ServiceCommand {
    public func run() throws {
        let lifecycle = Self.lifecycle
        try bootstrap()
        try configure(lifecycle)
        lifecycle.start { error in
            onStart(error)
        }
        lifecycle.wait()
    }
}

extension ServiceCommand {
    public static var lifecycle: ServiceLifecycle {
        ServiceLifecycle()
    }
}

extension ServiceCommand {
    public func onStart(_ error: Error?) {
        if let error = error {
            Self.exit(withError: error)
        }
    }
}
