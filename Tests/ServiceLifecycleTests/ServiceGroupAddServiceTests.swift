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
final class ServiceGroupAddServiceTests: XCTestCase {

    func testAddService_whenNotRunning() async {
        let mockService = MockService(description: "Service1")
        let serviceGroup = self.makeServiceGroup()
        await serviceGroup.addServiceUnlessShutdown(mockService)

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

    func testAddService_whenRunning() async throws {
        let mockService1 = MockService(description: "Service1")
        let mockService2 = MockService(description: "Service2")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: mockService1)]
        )

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = mockService1.events.makeAsyncIterator()
            var eventIterator2 = mockService2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            await serviceGroup.addServiceUnlessShutdown(mockService2)
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            await mockService1.resumeRunContinuation(with: .success(()))

            await XCTAsyncAssertEqual(await eventIterator2.next(), .runCancelled)
            await mockService2.resumeRunContinuation(with: .success(()))
        }
    }

    func testAddService_whenShuttingDown() async throws {
        let mockService1 = MockService(description: "Service1")
        let mockService2 = MockService(description: "Service2")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: mockService1)]
        )

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = mockService1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            await serviceGroup.triggerGracefulShutdown()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .shutdownGracefully)

            await serviceGroup.addServiceUnlessShutdown(mockService2)

            await mockService1.resumeRunContinuation(with: .success(()))
        }

        await XCTAsyncAssertEqual(await mockService2.hasRun, false)
    }

    func testAddService_whenCancelling() async throws {
        let mockService1 = MockService(description: "Service1")
        let mockService2 = MockService(description: "Service2")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: mockService1)]
        )

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = mockService1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            group.cancelAll()

            await XCTAsyncAssertEqual(await eventIterator1.next(), .runCancelled)
            await serviceGroup.addServiceUnlessShutdown(mockService2)

            await mockService1.resumeRunContinuation(with: .success(()))
        }

        await XCTAsyncAssertEqual(await mockService2.hasRun, false)
    }

    func testRun_whenAddedServiceExitsEarly_andIgnore() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let serviceGroup = self.makeServiceGroup(
            services: [],
            gracefulShutdownSignals: [.sigalrm]
        )

        await serviceGroup.addServiceUnlessShutdown(.init(service: service1, successTerminationBehavior: .ignore))

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            await serviceGroup.addServiceUnlessShutdown(.init(service: service2, failureTerminationBehavior: .ignore))
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            await service1.resumeRunContinuation(with: .success(()))

            service2.sendPing()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .runPing)

            await service2.resumeRunContinuation(with: .failure(ExampleError()))

            try await XCTAsyncAssertNoThrow(await group.next())
        }
    }

    func testRun_whenAddedServiceExitsEarly_andShutdownGracefully() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let serviceGroup = self.makeServiceGroup(
            services: [
                .init(service: service1)
            ]
        )

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            await serviceGroup.addServiceUnlessShutdown(
                .init(service: service2, successTerminationBehavior: .gracefullyShutdownGroup)
            )
            await serviceGroup.addServiceUnlessShutdown(.init(service: service3))

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

    func testRun_whenAddedServiceThrows() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: service1)],
            gracefulShutdownSignals: [.sigalrm]
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var service1EventIterator = service1.events.makeAsyncIterator()
            var service2EventIterator = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await service1EventIterator.next(), .run)
            await serviceGroup.addServiceUnlessShutdown(service2)

            await XCTAsyncAssertEqual(await service2EventIterator.next(), .run)

            // Throwing from service2 here and expect that service1 gets cancelled
            await service2.resumeRunContinuation(with: .failure(ExampleError()))

            await XCTAsyncAssertEqual(await service1EventIterator.next(), .runCancelled)
            await service1.resumeRunContinuation(with: .success(()))

            try await XCTAsyncAssertThrowsError(await group.next()) {
                XCTAssertTrue($0 is ExampleError)
            }
        }
    }

    #if !os(Windows)
    func testGracefulShutdownOrdering_withAddedServices() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: service1)],
            gracefulShutdownSignals: [.sigalrm]
        )

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            await serviceGroup.addServiceUnlessShutdown(service2)
            await serviceGroup.addServiceUnlessShutdown(service3)

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

    func testGracefulShutdownOrdering_whenAddedServiceExits() async throws {
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")

        let serviceGroup = self.makeServiceGroup(
            services: [.init(service: service1)],
            gracefulShutdownSignals: [.sigalrm]
        )

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serviceGroup.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            await serviceGroup.addServiceUnlessShutdown(service2)
            await serviceGroup.addServiceUnlessShutdown(service3)

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
