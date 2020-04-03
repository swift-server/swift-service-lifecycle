//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftServiceLauncher open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the SwiftServiceLauncher project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftServiceLauncher project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
//
// TopLevelTests+XCTest.swift
//
import XCTest

///
/// NOTE: This file was generated by generate_linux_tests.rb
///
/// Do NOT edit this file directly as it will be regenerated automatically when needed.
///

extension TopLevelTests {
    static var allTests: [(String, (TopLevelTests) -> () throws -> Void)] {
        return [
            ("testShutdownWithSignal", testShutdownWithSignal),
            ("testStartAndWait", testStartAndWait),
            ("testBadStartAndWait", testBadStartAndWait),
            ("testNesting", testNesting),
        ]
    }
}
