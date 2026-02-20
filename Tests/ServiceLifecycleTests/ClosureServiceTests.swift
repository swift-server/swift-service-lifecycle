//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftServiceLifecycle open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftServiceLifecycle project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftServiceLifecycle project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ServiceLifecycle
import Testing

struct ClosureServiceTests {
    @Test
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    func runExecutesClosure() async throws {
        try await confirmation { executed in
            let service = ClosureService {
                executed()
            }
            try await service.run()
        }
    }

    @Test
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    func runPropagatesErrors() async {
        struct TestError: Error {}

        let service = ClosureService {
            throw TestError()
        }

        await #expect(throws: TestError.self) {
            try await service.run()
        }
    }
}
