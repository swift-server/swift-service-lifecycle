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
// LifecycleTests+XCTest.swift
//
import XCTest

///
/// NOTE: This file was generated by generate_linux_tests.rb
///
/// Do NOT edit this file directly as it will be regenerated automatically when needed.
///

extension Tests {
    static var allTests: [(String, (Tests) -> () throws -> Void)] {
        return [
            ("testStartThenShutdown", testStartThenShutdown),
            ("testDefaultCallbackQueue", testDefaultCallbackQueue),
            ("testUserDefinedCallbackQueue", testUserDefinedCallbackQueue),
            ("testShutdownWhileStarting", testShutdownWhileStarting),
            ("testShutdownWhenIdle", testShutdownWhenIdle),
            ("testShutdownWhenShutdown", testShutdownWhenShutdown),
            ("testShutdownDuringHangingStart", testShutdownDuringHangingStart),
            ("testShutdownErrors", testShutdownErrors),
            ("testStartupErrors", testStartupErrors),
            ("testStartAndWait", testStartAndWait),
            ("testBadStartAndWait", testBadStartAndWait),
            ("testShutdownInOrder", testShutdownInOrder),
            ("testSync", testSync),
            ("testAyncBarrier", testAyncBarrier),
            ("testConcurrency", testConcurrency),
            ("testRegisterSync", testRegisterSync),
            ("testRegisterShutdownSync", testRegisterShutdownSync),
            ("testRegisterAsync", testRegisterAsync),
            ("testRegisterShutdownAsync", testRegisterShutdownAsync),
            ("testRegisterAsyncClosure", testRegisterAsyncClosure),
            ("testRegisterShutdownAsyncClosure", testRegisterShutdownAsyncClosure),
            ("testRegisterNIO", testRegisterNIO),
            ("testRegisterShutdownNIO", testRegisterShutdownNIO),
            ("testRegisterNIOClosure", testRegisterNIOClosure),
            ("testRegisterShutdownNIOClosure", testRegisterShutdownNIOClosure),
            ("testNIOFailure", testNIOFailure),
            ("testExternalState", testExternalState),
        ]
    }
}
