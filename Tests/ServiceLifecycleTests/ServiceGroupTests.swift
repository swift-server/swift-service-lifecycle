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

import Logging
import ServiceLifecycle
import UnixSignals
import XCTest

private struct ExampleError: Error, Hashable {}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
final class ServiceGroupTests: XCTestCase {
    func testRun_whenAlreadyRunning() async throws {
        let mockService = MockService(description: "Service1")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: mockService)]
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator = mockService.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator.next(), .run)

            try await XCTAsyncAssertThrowsError(await serviceGroup.run()) {
                XCTAssertEqual($0 as? ServiceGroupError, .alreadyRunning())
            }

            group.cancelAll()
            await mockService.resumeRunContinuation(with: .success(()))
        }
    }

    func testRun_whenAlreadyFinished() async throws {
        let group = self.makeServiceGroup()

        try await group.run()

        try await XCTAsyncAssertThrowsError(await group.run()) {
            XCTAssertEqual($0 as? ServiceGroupError, .alreadyFinished())
        }
    }

    func testRun_whenNoService_andNoSignal() async throws {
        let group = self.makeServiceGroup()

        try await group.run()
    }

    func testRun_whenNoSignal() async throws {
        let mockService = MockService(description: "Service1")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: mockService)]
        )

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator = mockService.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator.next(), .run)

            group.cancelAll()
            await XCTAsyncAssertEqual(await eventIterator.next(), .runCancelled)

            await mockService.resumeRunContinuation(with: .success(()))
        }
    }

    #if !os(Windows)
    func test_whenRun_ShutdownGracefully() async throws {
        let mockService = MockService(description: "Service1")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: mockService)],
            gracefulShutdownSignals: [.sigalrm]
        )

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator = mockService.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator.next(), .run)

            let pid = getpid()
            kill(pid, UnixSignal.sigalrm.rawValue)  // ignore-unacceptable-language
            await XCTAsyncAssertEqual(await eventIterator.next(), .shutdownGracefully)

            await mockService.resumeRunContinuation(with: .success(()))
        }
    }
    #endif

    func testRun_whenServiceExitsEarly() async throws {
        let mockService = MockService(description: "Service1")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: mockService)],
            gracefulShutdownSignals: [.sigalrm]
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator = mockService.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator.next(), .run)

            await mockService.resumeRunContinuation(with: .success(()))

            try await XCTAsyncAssertThrowsError(await group.next()) {
                XCTAssertEqual(
                    $0 as? ServiceGroupError,
                    .serviceFinishedUnexpectedly(service: "Service1")
                )
            }
        }
    }

    func testRun_whenServiceExitsEarly_andIgnore() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let serviceGroup = self.makeServiceGroup(
            services: [
                .init(service: service1, successTerminationBehavior: .ignore),
                .init(service: service2, failureTerminationBehavior: .ignore),
            ],
            gracefulShutdownSignals: [.sigalrm]
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            await service1.resumeRunContinuation(with: .success(()))

            service2.sendPing()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)

            await service2.resumeRunContinuation(with: .failure(ExampleError()))

            try await XCTAsyncAssertNoThrow(await group.next())
        }
    }

    func testRun_whenServiceExitsEarly_andShutdownGracefully() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let serviceGroup = self.makeServiceGroup(
            services: [
                .init(service: service1),
                .init(service: service2, successTerminationBehavior: .gracefullyShutdownGroup),
                .init(service: service3),
            ]
        )

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            var eventIterator3 = service3.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

            await service2.resumeRunContinuation(with: .success(()))

            // The last service should receive the shutdown signal first
            await XCTAsyncAssertEqual(await eventIterator3.next(), .shutdownGracefully)

            // Waiting to see that the remaining two are still running
            service1.sendPing()
            service3.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator3.next(), .runPing)

            // Let's exit from the last service
            await service3.resumeRunContinuation(with: .success(()))

            // Waiting to see that the remaining is still running
            await XCTAsyncAssertEqual(await eventIterator1.next(), .shutdownGracefully)
            service1.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)

            // Let's exit from the first service
            await service1.resumeRunContinuation(with: .success(()))
        }
    }

    func testRun_whenServiceExitsEarly_andShutdownGracefully_andThenCancels() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let serviceGroup = self.makeServiceGroup(
            services: [
                .init(service: service1),
                .init(service: service2, successTerminationBehavior: .cancelGroup),
                .init(service: service3, successTerminationBehavior: .gracefullyShutdownGroup),
            ]
        )

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            var eventIterator3 = service3.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

            await service3.resumeRunContinuation(with: .success(()))

            // The second service should receive the shutdown signal first
            await XCTAsyncAssertEqual(await eventIterator2.next(), .shutdownGracefully)

            // Waiting to see that all two are still running
            service1.sendPing()
            service2.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)

            // Let's exit from the second service
            await service2.resumeRunContinuation(with: .success(()))

            // Waiting to see that the remaining is still running
            await XCTAsyncAssertEqual(await eventIterator1.next(), .shutdownGracefully)
            service1.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)

            // Waiting to see that the one remaining are still running
            service1.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)

            // Let's exit from the first service
            await service1.resumeRunContinuation(with: .success(()))
        }
    }

    func testRun_whenServiceExitsEarly_andOtherRunningService() async throws {
        let shortService = MockService(description: "Service1")
        let longService = MockService(description: "Service2")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: shortService), .init(service: longService)],
            gracefulShutdownSignals: [.sigalrm]
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var shortServiceEventIterator = shortService.events.makeAsyncIterator()
            var longServiceEventIterator = longService.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await shortServiceEventIterator.next(), .run)
            await XCTAsyncAssertEqual(await longServiceEventIterator.next(), .run)

            // Finishing the short running service here
            await shortService.resumeRunContinuation(with: .success(()))

            // Checking that the long running service is still running
            await XCTAsyncAssertEqual(await longServiceEventIterator.next(), .runCancelled)
            // Finishing the long running service here
            await longService.resumeRunContinuation(with: .success(()))

            try await XCTAsyncAssertThrowsError(await group.next()) {
                XCTAssertEqual(
                    $0 as? ServiceGroupError,
                    .serviceFinishedUnexpectedly(service: "Service1")
                )
            }
        }
    }

    func testRun_whenServiceThrows() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: service1), .init(service: service2)],
            gracefulShutdownSignals: [.sigalrm]
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var service1EventIterator = service1.events.makeAsyncIterator()
            var service2EventIterator = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await service1EventIterator.next(), .run)
            await XCTAsyncAssertEqual(await service2EventIterator.next(), .run)
            service1.sendPing()
            service2.sendPing()
            await XCTAsyncAssertEqual(await service1EventIterator.next(), .runPing)
            await XCTAsyncAssertEqual(await service2EventIterator.next(), .runPing)

            // Throwing from service1 here and expect that service2 gets cancelled
            await service1.resumeRunContinuation(with: .failure(ExampleError()))

            await XCTAsyncAssertEqual(await service2EventIterator.next(), .runCancelled)
            await service2.resumeRunContinuation(with: .success(()))

            try await XCTAsyncAssertThrowsError(await group.next()) {
                XCTAssertTrue($0 is ExampleError)
            }
        }
    }

    func testRun_whenServiceThrows_andIgnore() async throws {
        let mockService = MockService(description: "Service1")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: mockService, failureTerminationBehavior: .ignore)],
            gracefulShutdownSignals: [.sigalrm]
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator = mockService.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator.next(), .run)

            await mockService.resumeRunContinuation(with: .failure(ExampleError()))

            try await XCTAsyncAssertNoThrow(await group.next())
        }
    }

    func testRun_whenServiceThrows_andShutdownGracefully() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let serviceGroup = self.makeServiceGroup(
            services: [
                .init(service: service1),
                .init(service: service2, failureTerminationBehavior: .gracefullyShutdownGroup),
                .init(service: service3),
            ]
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            var eventIterator3 = service3.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

            await service2.resumeRunContinuation(with: .failure(ExampleError()))

            // The last service should receive the shutdown signal first
            await XCTAsyncAssertEqual(await eventIterator3.next(), .shutdownGracefully)

            // Waiting to see that all two are still running
            service1.sendPing()
            service3.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator3.next(), .runPing)

            // Let's exit from the last service
            await service3.resumeRunContinuation(with: .success(()))

            // Waiting to see that the remaining is still running
            service1.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)

            // The first service should now receive the signal
            await XCTAsyncAssertEqual(await eventIterator1.next(), .shutdownGracefully)

            // Waiting to see that the one remaining are still running
            service1.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)

            // Let's exit from the first service
            await service1.resumeRunContinuation(with: .success(()))

            try await XCTAsyncAssertThrowsError(await group.next()) {
                XCTAssertTrue($0 is ExampleError)
            }
        }
    }

    func testRun_whenServiceThrows_andShutdownGracefully_andOtherServiceThrows() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let serviceGroup = self.makeServiceGroup(
            services: [
                .init(service: service1),
                .init(service: service2, failureTerminationBehavior: .gracefullyShutdownGroup),
                .init(service: service3),
            ]
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            var eventIterator3 = service3.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

            await service2.resumeRunContinuation(with: .failure(ExampleError()))

            // The last service should receive the shutdown signal first
            await XCTAsyncAssertEqual(await eventIterator3.next(), .shutdownGracefully)

            // Waiting to see that all two are still running
            service1.sendPing()
            service3.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator3.next(), .runPing)

            // Let's exit from the last service
            await service3.resumeRunContinuation(with: .success(()))

            // Waiting to see that the remaining is still running
            await XCTAsyncAssertEqual(await eventIterator1.next(), .shutdownGracefully)
            service1.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)

            // Waiting to see that the one remaining are still running
            service1.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)

            // Let's throw from this service as well
            struct OtherError: Error {}
            await service1.resumeRunContinuation(with: .failure(OtherError()))

            try await XCTAsyncAssertThrowsError(await group.next()) {
                XCTAssertTrue($0 is ExampleError)
            }
        }
    }

    #if !os(Windows)
    func testCancellationSignal() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: service1), .init(service: service2), .init(service: service3)],
            cancellationSignals: [.sigalrm]
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            var eventIterator3 = service3.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

            let pid = getpid()
            kill(pid, UnixSignal.sigalrm.rawValue)  // ignore-unacceptable-language

            await XCTAsyncAssertEqual(await eventIterator1.next(), .runCancelled)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runCancelled)
            await XCTAsyncAssertEqual(await eventIterator3.next(), .runCancelled)

            // Let's exit from all services
            await service1.resumeRunContinuation(with: .success(()))
            await service2.resumeRunContinuation(with: .success(()))
            await service3.resumeRunContinuation(with: .success(()))

            await XCTAsyncAssertNoThrow(try await group.next())
        }
    }
    #endif

    #if !os(Windows)
    func testCancellationSignal_afterGracefulShutdownSignal() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: service1), .init(service: service2), .init(service: service3)],
            gracefulShutdownSignals: [.sigwinch],
            cancellationSignals: [.sigalrm]
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            var eventIterator3 = service3.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

            let pid = getpid()
            kill(pid, UnixSignal.sigwinch.rawValue)  // ignore-unacceptable-language

            await XCTAsyncAssertEqual(await eventIterator3.next(), .shutdownGracefully)

            // Waiting to see that all services are still running.
            service1.sendPing()
            service2.sendPing()
            service3.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator3.next(), .runPing)

            // Now we signal cancellation
            kill(pid, UnixSignal.sigalrm.rawValue)  // ignore-unacceptable-language

            await XCTAsyncAssertEqual(await eventIterator1.next(), .runCancelled)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runCancelled)
            await XCTAsyncAssertEqual(await eventIterator3.next(), .runCancelled)

            // Let's exit from all services
            await service1.resumeRunContinuation(with: .success(()))
            await service2.resumeRunContinuation(with: .success(()))
            await service3.resumeRunContinuation(with: .success(()))

            await XCTAsyncAssertNoThrow(try await group.next())
        }
    }
    #endif

    #if !os(Windows)
    func testGracefulShutdownOrdering() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: service1), .init(service: service2), .init(service: service3)],
            gracefulShutdownSignals: [.sigalrm]
        )

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            var eventIterator3 = service3.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

            let pid = getpid()
            kill(pid, UnixSignal.sigalrm.rawValue)  // ignore-unacceptable-language

            // The last service should receive the shutdown signal first
            await XCTAsyncAssertEqual(await eventIterator3.next(), .shutdownGracefully)

            // Waiting to see that all three are still running
            service1.sendPing()
            service2.sendPing()
            service3.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator3.next(), .runPing)

            // Let's exit from the last service
            await service3.resumeRunContinuation(with: .success(()))

            // The middle service should now receive the signal
            await XCTAsyncAssertEqual(await eventIterator2.next(), .shutdownGracefully)

            // Waiting to see that the two remaining are still running
            service1.sendPing()
            service2.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)

            // Let's exit from the middle service
            await service2.resumeRunContinuation(with: .success(()))

            // The first service should now receive the signal
            await XCTAsyncAssertEqual(await eventIterator1.next(), .shutdownGracefully)

            // Waiting to see that the one remaining are still running
            service1.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)

            // Let's exit from the first service
            await service1.resumeRunContinuation(with: .success(()))
        }
    }
    #endif

    #if !os(Windows)
    func testGracefulShutdownOrdering_whenServiceThrows() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: service1), .init(service: service2), .init(service: service3)],
            gracefulShutdownSignals: [.sigalrm]
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            var eventIterator3 = service3.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

            let pid = getpid()
            kill(pid, UnixSignal.sigalrm.rawValue)  // ignore-unacceptable-language

            // The last service should receive the shutdown signal first
            await XCTAsyncAssertEqual(await eventIterator3.next(), .shutdownGracefully)

            // Waiting to see that all three are still running
            service1.sendPing()
            service2.sendPing()
            service3.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator3.next(), .runPing)

            // Let's exit from the last service
            await service3.resumeRunContinuation(with: .success(()))

            // The middle service should now receive the signal
            await XCTAsyncAssertEqual(await eventIterator2.next(), .shutdownGracefully)

            // Waiting to see that the two remaining are still running
            service1.sendPing()
            service2.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)

            // Let's throw from the middle service
            await service2.resumeRunContinuation(with: .failure(ExampleError()))

            // The first service should now receive a cancellation
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runCancelled)

            // Let's exit from the first service
            await service1.resumeRunContinuation(with: .success(()))

            try await XCTAsyncAssertThrowsError(await group.next()) {
                XCTAssertTrue($0 is ExampleError)
            }
        }
    }
    #endif

    #if !os(Windows)
    func testGracefulShutdownOrdering_whenServiceThrows_andServiceGracefullyShutsdown() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let serviceGroup = self.makeServiceGroup(
            services: [
                .init(service: service1),
                .init(service: service2, failureTerminationBehavior: .gracefullyShutdownGroup),
                .init(service: service3),
            ],
            gracefulShutdownSignals: [.sigalrm]
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            var eventIterator3 = service3.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

            let pid = getpid()
            kill(pid, UnixSignal.sigalrm.rawValue)  // ignore-unacceptable-language

            // The last service should receive the shutdown signal first
            await XCTAsyncAssertEqual(await eventIterator3.next(), .shutdownGracefully)

            // Waiting to see that all three are still running
            service1.sendPing()
            service2.sendPing()
            service3.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator3.next(), .runPing)

            // Let's exit from the last service
            await service3.resumeRunContinuation(with: .success(()))

            // The middle service should now receive the signal
            await XCTAsyncAssertEqual(await eventIterator2.next(), .shutdownGracefully)

            // Waiting to see that the two remaining are still running
            service1.sendPing()
            service2.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)

            // Let's throw from the middle service
            await service2.resumeRunContinuation(with: .failure(ExampleError()))

            // The first service should now receive a cancellation
            await XCTAsyncAssertEqual(await eventIterator1.next(), .shutdownGracefully)

            // Let's exit from the first service
            await service1.resumeRunContinuation(with: .success(()))

            try await XCTAsyncAssertThrowsError(await group.next()) {
                XCTAssertTrue($0 is ExampleError)
            }
        }
    }
    #endif

    #if !os(Windows)
    func testGracefulShutdownOrdering_whenServiceExits() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: service1), .init(service: service2), .init(service: service3)],
            gracefulShutdownSignals: [.sigalrm]
        )

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            var eventIterator3 = service3.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

            let pid = getpid()
            kill(pid, UnixSignal.sigalrm.rawValue)  // ignore-unacceptable-language

            // The last service should receive the shutdown signal first
            await XCTAsyncAssertEqual(await eventIterator3.next(), .shutdownGracefully)

            // Waiting to see that all three are still running
            service1.sendPing()
            service2.sendPing()
            service3.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator3.next(), .runPing)

            // Let's exit from the last service
            await service3.resumeRunContinuation(with: .success(()))

            // The middle service should now receive the signal
            await XCTAsyncAssertEqual(await eventIterator2.next(), .shutdownGracefully)

            // Waiting to see that the two remaining are still running
            service1.sendPing()
            service2.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)

            // Let's exit from the first service
            await service1.resumeRunContinuation(with: .success(()))

            // The middle service should now receive a cancellation
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runCancelled)

            // Let's exit from the first service
            await service2.resumeRunContinuation(with: .success(()))
        }
    }
    #endif

    #if !os(Windows)
    func testGracefulShutdownOrdering_whenServiceExits_andIgnoringThrows() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let serviceGroup = self.makeServiceGroup(
            services: [
                .init(service: service1, failureTerminationBehavior: .gracefullyShutdownGroup),
                .init(service: service2, failureTerminationBehavior: .ignore),
                .init(service: service3, successTerminationBehavior: .ignore),
            ],
            gracefulShutdownSignals: [.sigalrm]
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            var eventIterator3 = service3.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

            let pid = getpid()
            kill(pid, UnixSignal.sigalrm.rawValue)  // ignore-unacceptable-language

            // The last service should receive the shutdown signal first
            await XCTAsyncAssertEqual(await eventIterator3.next(), .shutdownGracefully)

            // Waiting to see that all three are still running
            service1.sendPing()
            service2.sendPing()
            service3.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator3.next(), .runPing)

            // Let's exit from the last service
            await service3.resumeRunContinuation(with: .success(()))

            // The middle service should now receive the signal
            await XCTAsyncAssertEqual(await eventIterator2.next(), .shutdownGracefully)

            // Waiting to see that the two remaining are still running
            service1.sendPing()
            service2.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)

            // Let's throw from the second service
            await service2.resumeRunContinuation(with: .failure(ExampleError()))

            // The first service should still be running but seeing a graceful shutdown signal firsts
            await XCTAsyncAssertEqual(await eventIterator1.next(), .shutdownGracefully)
            service1.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)

            // Let's throw from the first service
            await service1.resumeRunContinuation(with: .failure(ExampleError()))

            try await XCTAsyncAssertThrowsError(await group.next()) {
                XCTAssertTrue($0 is ExampleError)
            }
        }
    }
    #endif

    #if !os(Windows)
    func testNestedServiceLifecycle() async throws {
        struct NestedGroupService: Service {
            let group: ServiceGroup

            init(group: ServiceGroup) {
                self.group = group
            }

            func run() async throws {
                try await self.group.run()
            }
        }

        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let nestedGroupService = NestedGroupService(
            group: self.makeServiceGroup(
                services: [.init(service: service2)]
            )
        )
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: service1), .init(service: nestedGroupService)],
            gracefulShutdownSignals: [.sigalrm]
        )

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            var eventIterator2 = service2.events.makeAsyncIterator()
            service1.sendPing()
            service2.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)

            let pid = getpid()
            kill(pid, UnixSignal.sigalrm.rawValue)  // ignore-unacceptable-language
            await XCTAsyncAssertEqual(await eventIterator2.next(), .shutdownGracefully)

            service1.sendPing()
            service2.sendPing()

            // Waiting to see that the two remaining are still running
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)

            // Let's exit from the second service
            await service2.resumeRunContinuation(with: .success(()))

            service1.sendPing()
            // Waiting to see that the remaining is still running
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)

            // Let's exit from the first service
            await service1.resumeRunContinuation(with: .success(()))
        }
    }

    func testTriggerGracefulShutdown() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: service1), .init(service: service2), .init(service: service3)]
        )

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            var eventIterator3 = service3.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

            await serviceGroup.triggerGracefulShutdown()

            // The last service should receive the shutdown signal first
            await XCTAsyncAssertEqual(await eventIterator3.next(), .shutdownGracefully)

            // Waiting to see that all three are still running
            service1.sendPing()
            service2.sendPing()
            service3.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator3.next(), .runPing)

            // Let's exit from the last service
            await service3.resumeRunContinuation(with: .success(()))

            // The middle service should now receive the signal
            await XCTAsyncAssertEqual(await eventIterator2.next(), .shutdownGracefully)

            // Waiting to see that the two remaining are still running
            service1.sendPing()
            service2.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)

            // Let's exit from the first service
            await service1.resumeRunContinuation(with: .success(()))

            // The middle service should now receive a cancellation
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runCancelled)

            // Let's exit from the first service
            await service2.resumeRunContinuation(with: .success(()))
        }
    }
    #endif

    func testGracefulShutdownEscalation() async throws {
        let mockService = MockService(description: "Service1")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: mockService)],
            gracefulShutdownSignals: [.sigalrm],
            maximumGracefulShutdownDuration: .seconds(0.1),
            maximumCancellationDuration: .seconds(0.5)
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator = mockService.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator.next(), .run)

            await serviceGroup.triggerGracefulShutdown()

            await XCTAsyncAssertEqual(await eventIterator.next(), .shutdownGracefully)

            await XCTAsyncAssertEqual(await eventIterator.next(), .runCancelled)

            try await Task.sleep(for: .seconds(0.2))

            await mockService.resumeRunContinuation(with: .success(()))

            try await XCTAsyncAssertNoThrow(await group.next())
        }
    }

    func testGracefulShutdownWithMaximumDuration() async throws {
        let mockService = MockService(description: "Service1")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: mockService)],
            gracefulShutdownSignals: [.sigalrm],
            maximumGracefulShutdownDuration: .seconds(0.1)
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator = mockService.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator.next(), .run)

            await serviceGroup.triggerGracefulShutdown()

            await XCTAsyncAssertEqual(await eventIterator.next(), .shutdownGracefully)

            await mockService.resumeRunContinuation(with: .success(()))

            try await XCTAsyncAssertNoThrow(await group.next())
        }
    }

    func testGracefulShutdownEscalation_whenNoCancellationEscalation() async throws {
        let mockService = MockService(description: "Service1")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: mockService)],
            gracefulShutdownSignals: [.sigalrm],
            maximumGracefulShutdownDuration: .seconds(0.1),
            maximumCancellationDuration: nil
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator = mockService.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator.next(), .run)

            await serviceGroup.triggerGracefulShutdown()

            await XCTAsyncAssertEqual(await eventIterator.next(), .shutdownGracefully)

            await XCTAsyncAssertEqual(await eventIterator.next(), .runCancelled)

            try await Task.sleep(for: .seconds(0.2))

            await mockService.resumeRunContinuation(with: .success(()))

            try await XCTAsyncAssertNoThrow(await group.next())
        }
    }

    func testCancellationEscalation() async throws {
        let mockService = MockService(description: "Service1")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: mockService)],
            gracefulShutdownSignals: [.sigalrm],
            maximumGracefulShutdownDuration: nil,
            maximumCancellationDuration: .seconds(1)
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator = mockService.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator.next(), .run)

            group.cancelAll()

            await XCTAsyncAssertEqual(await eventIterator.next(), .runCancelled)

            try await Task.sleep(for: .seconds(0.1))

            await mockService.resumeRunContinuation(with: .success(()))

            try await XCTAsyncAssertNoThrow(await group.next())
        }
    }

    func testTriggerGracefulShutdown_serviceThrows_inOrder_gracefullyShutdownGroup() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let serviceGroup = self.makeServiceGroup(
            services: [
                .init(service: service1, failureTerminationBehavior: .gracefullyShutdownGroup),
                .init(service: service2, failureTerminationBehavior: .gracefullyShutdownGroup),
                .init(service: service3, failureTerminationBehavior: .gracefullyShutdownGroup),
            ]
        )

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await serviceGroup.run()
                }

                var eventIterator1 = service1.events.makeAsyncIterator()
                await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

                var eventIterator2 = service2.events.makeAsyncIterator()
                await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

                var eventIterator3 = service3.events.makeAsyncIterator()
                await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

                await serviceGroup.triggerGracefulShutdown()

                // The last service should receive the shutdown signal first
                await XCTAsyncAssertEqual(await eventIterator3.next(), .shutdownGracefully)

                // Waiting to see that all three are still running
                service1.sendPing()
                service2.sendPing()
                service3.sendPing()
                await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
                await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)
                await XCTAsyncAssertEqual(await eventIterator3.next(), .runPing)

                // Let's exit from the last service
                await service3.resumeRunContinuation(with: .success(()))

                // The middle service should now receive the signal
                await XCTAsyncAssertEqual(await eventIterator2.next(), .shutdownGracefully)

                // Waiting to see that the two remaining are still running
                service1.sendPing()
                service2.sendPing()
                await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
                await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)

                // Let's exit from the second service
                await service2.resumeRunContinuation(with: .failure(ExampleError()))

                // The final service should now receive the signal
                await XCTAsyncAssertEqual(await eventIterator1.next(), .shutdownGracefully)

                // Waiting to see that the one remaining are still running
                service1.sendPing()
                await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)

                // Let's exit from the first service
                await service1.resumeRunContinuation(with: .success(()))

                try await group.waitForAll()
            }

            XCTFail("Expected error not thrown")
        } catch is ExampleError {
            // expected error
        }
    }

    func testTriggerGracefulShutdown_serviceThrows_inOrder_ignore() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let serviceGroup = self.makeServiceGroup(
            services: [
                .init(service: service1, failureTerminationBehavior: .ignore),
                .init(service: service2, failureTerminationBehavior: .ignore),
                .init(service: service3, failureTerminationBehavior: .ignore),
            ]
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            var eventIterator3 = service3.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

            await serviceGroup.triggerGracefulShutdown()

            // The last service should receive the shutdown signal first
            await XCTAsyncAssertEqual(await eventIterator3.next(), .shutdownGracefully)

            // Waiting to see that all three are still running
            service1.sendPing()
            service2.sendPing()
            service3.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator3.next(), .runPing)

            // Let's exit from the last service
            await service3.resumeRunContinuation(with: .success(()))

            // The middle service should now receive the signal
            await XCTAsyncAssertEqual(await eventIterator2.next(), .shutdownGracefully)

            // Waiting to see that the two remaining are still running
            service1.sendPing()
            service2.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)

            // Let's exit from the second service
            await service2.resumeRunContinuation(with: .failure(ExampleError()))

            // The final service should now receive the signal
            await XCTAsyncAssertEqual(await eventIterator1.next(), .shutdownGracefully)

            // Waiting to see that the one remaining are still running
            service1.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)

            // Let's exit from the first service
            await service1.resumeRunContinuation(with: .success(()))

            try await group.waitForAll()
        }
    }

    func testTriggerGracefulShutdown_serviceThrows_outOfOrder_gracefullyShutdownGroup() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let serviceGroup = self.makeServiceGroup(
            services: [
                .init(service: service1, failureTerminationBehavior: .gracefullyShutdownGroup),
                .init(service: service2, failureTerminationBehavior: .gracefullyShutdownGroup),
                .init(service: service3, failureTerminationBehavior: .gracefullyShutdownGroup),
            ]
        )

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await serviceGroup.run()
                }

                var eventIterator1 = service1.events.makeAsyncIterator()
                await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

                var eventIterator2 = service2.events.makeAsyncIterator()
                await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

                var eventIterator3 = service3.events.makeAsyncIterator()
                await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

                await serviceGroup.triggerGracefulShutdown()

                // The last service should receive the shutdown signal first
                await XCTAsyncAssertEqual(await eventIterator3.next(), .shutdownGracefully)

                // Waiting to see that all three are still running
                service1.sendPing()
                service2.sendPing()
                service3.sendPing()
                await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
                await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)
                await XCTAsyncAssertEqual(await eventIterator3.next(), .runPing)

                // Let's exit from the last service
                await service3.resumeRunContinuation(with: .success(()))

                // The middle service should now receive the signal
                await XCTAsyncAssertEqual(await eventIterator2.next(), .shutdownGracefully)

                // Waiting to see that the two remaining are still running
                service1.sendPing()
                service2.sendPing()
                await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
                await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)

                // Let's exit from the first service (even though the second service
                // is gracefully shutting down)
                await service1.resumeRunContinuation(with: .failure(ExampleError()))

                // Waiting to see that the one remaining are still running
                service2.sendPing()
                await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)

                // Let's exit from the second service
                await service2.resumeRunContinuation(with: .success(()))

                // The first service shutdown will be skipped
                try await group.waitForAll()
            }

            XCTFail("Expected error not thrown")
        } catch is ExampleError {
            // expected error
        }
    }

    func testTriggerGracefulShutdown_serviceThrows_outOfOrder_ignore() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let serviceGroup = self.makeServiceGroup(
            services: [
                .init(service: service1, failureTerminationBehavior: .ignore),
                .init(service: service2, failureTerminationBehavior: .ignore),
                .init(service: service3, failureTerminationBehavior: .ignore),
            ]
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            var eventIterator3 = service3.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

            await serviceGroup.triggerGracefulShutdown()

            // The last service should receive the shutdown signal first
            await XCTAsyncAssertEqual(await eventIterator3.next(), .shutdownGracefully)

            // Waiting to see that all three are still running
            service1.sendPing()
            service2.sendPing()
            service3.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator3.next(), .runPing)

            // Let's exit from the last service
            await service3.resumeRunContinuation(with: .success(()))

            // The middle service should now receive the signal
            await XCTAsyncAssertEqual(await eventIterator2.next(), .shutdownGracefully)

            // Waiting to see that the two remaining are still running
            service1.sendPing()
            service2.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)

            // Let's exit from the first service (even though the second service
            // is gracefully shutting down)
            await service1.resumeRunContinuation(with: .failure(ExampleError()))

            // We are sleeping here for a tiny bit to make sure the error is handled from the service 1
            try await Task.sleep(for: .seconds(0.05))

            // Waiting to see that the one remaining are still running
            service2.sendPing()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)

            // Let's exit from the second service
            await service2.resumeRunContinuation(with: .success(()))

            // The first service shutdown will be skipped
            try await group.waitForAll()
        }
    }

    func testTriggerGracefulShutdown_whenNestedGroup() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let innerServiceGroup = self.makeServiceGroup(
            services: [.init(service: service1), .init(service: service2), .init(service: service3)]
        )

        var logger = Logger(label: "Tests")
        logger.logLevel = .debug

        let outerServiceGroup = ServiceGroup(
            services: [innerServiceGroup],
            logger: logger
        )

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await outerServiceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            var eventIterator3 = service3.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

            await outerServiceGroup.triggerGracefulShutdown()

            // The last service should receive the shutdown signal first
            await XCTAsyncAssertEqual(await eventIterator3.next(), .shutdownGracefully)

            // Waiting to see that all three are still running
            service1.sendPing()
            service2.sendPing()
            service3.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator3.next(), .runPing)

            // Let's exit from the last service
            await service3.resumeRunContinuation(with: .success(()))

            // The middle service should now receive the signal
            await XCTAsyncAssertEqual(await eventIterator2.next(), .shutdownGracefully)

            // Waiting to see that the two remaining are still running
            service1.sendPing()
            service2.sendPing()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runPing)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)

            // Let's exit from the first service
            await service1.resumeRunContinuation(with: .success(()))

            // The middle service should now receive a cancellation
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runCancelled)

            // Let's exit from the first service
            await service2.resumeRunContinuation(with: .success(()))
        }
    }

    // MARK: - Helpers

    private func makeServiceGroup(
        services: [ServiceGroupConfiguration.ServiceConfiguration] = [],
        gracefulShutdownSignals: [UnixSignal] = .init(),
        cancellationSignals: [UnixSignal] = .init(),
        maximumGracefulShutdownDuration: Duration? = nil,
        maximumCancellationDuration: Duration? = .seconds(5)
    ) -> ServiceGroup {
        var logger = Logger(label: "Tests")
        logger.logLevel = .debug

        var configuration = ServiceGroupConfiguration(
            services: services,
            gracefulShutdownSignals: gracefulShutdownSignals,
            cancellationSignals: cancellationSignals,
            logger: logger
        )
        configuration.maximumGracefulShutdownDuration = maximumGracefulShutdownDuration
        configuration.maximumCancellationDuration = maximumCancellationDuration
        return .init(
            configuration: configuration
        )
    }
}
