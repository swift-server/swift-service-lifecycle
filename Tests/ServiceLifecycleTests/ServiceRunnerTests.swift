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

private actor MockService: Service, CustomStringConvertible {
    enum Event {
        case run
        case runPing
        case runCancelled
        case shutdownGracefully
    }

    let events: AsyncStream<Event>

    private let eventsContinuation: AsyncStream<Event>.Continuation

    private var runContinuation: CheckedContinuation<Void, Error>?

    nonisolated let description: String

    private let pings: AsyncStream<Void>
    private nonisolated let pingContinuation: AsyncStream<Void>.Continuation

    init(
        description: String
    ) {
        var eventsContinuation: AsyncStream<Event>.Continuation!
        self.events = AsyncStream<Event> { eventsContinuation = $0 }
        self.eventsContinuation = eventsContinuation!

        var pingContinuation: AsyncStream<Void>.Continuation!
        self.pings = AsyncStream<Void> { pingContinuation = $0 }
        self.pingContinuation = pingContinuation!

        self.description = description
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withGracefulShutdownHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        self.eventsContinuation.yield(.run)
                        for await _ in self.pings {
                            self.eventsContinuation.yield(.runPing)
                        }
                    }

                    try await withCheckedThrowingContinuation {
                        self.runContinuation = $0
                    }

                    group.cancelAll()
                }
            } onGracefulShutdown: {
                self.eventsContinuation.yield(.shutdownGracefully)
            }
        } onCancel: {
            self.eventsContinuation.yield(.runCancelled)
        }
    }

    func resumeRunContinuation(with result: Result<Void, Error>) {
        self.runContinuation?.resume(with: result)
    }

    nonisolated func sendPing() {
        self.pingContinuation.yield()
    }
}

final class ServiceRunnerTests: XCTestCase {
    func testRun_whenAlreadyRunning() async throws {
        let mockService = MockService(description: "Service1")
        let runner = self.makeServiceRunner(services: [mockService], configuration: .init(gracefulShutdownSignals: []))

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await runner.run()
            }

            var eventIterator = mockService.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator.next(), .run)

            try await XCTAsyncAssertThrowsError(await runner.run()) {
                XCTAssertEqual($0 as? ServiceRunnerError, .alreadyRunning())
            }

            group.cancelAll()
            await mockService.resumeRunContinuation(with: .success(()))
        }
    }

    func testRun_whenAlreadyFinished() async throws {
        let runner = self.makeServiceRunner(services: [], configuration: .init(gracefulShutdownSignals: []))

        try await runner.run()

        try await XCTAsyncAssertThrowsError(await runner.run()) {
            XCTAssertEqual($0 as? ServiceRunnerError, .alreadyFinished())
        }
    }

    func testRun_whenNoService_andNoSignal() async throws {
        let runner = self.makeServiceRunner(services: [], configuration: .init(gracefulShutdownSignals: []))

        try await runner.run()
    }

    func testRun_whenNoSignal() async throws {
        let mockService = MockService(description: "Service1")
        let runner = self.makeServiceRunner(services: [mockService], configuration: .init(gracefulShutdownSignals: []))

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await runner.run()
            }

            var eventIterator = mockService.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator.next(), .run)

            group.cancelAll()
            await XCTAsyncAssertEqual(await eventIterator.next(), .runCancelled)

            await mockService.resumeRunContinuation(with: .success(()))
        }
    }

    func test_whenRun_ShutdownGracefully() async throws {
        let configuration = ServiceRunnerConfiguration(gracefulShutdownSignals: [.sigalrm])
        let mockService = MockService(description: "Service1")
        let runner = self.makeServiceRunner(services: [mockService], configuration: configuration)

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await runner.run()
            }

            var eventIterator = mockService.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator.next(), .run)

            let pid = getpid()
            kill(pid, UnixSignal.sigalrm.rawValue)
            await XCTAsyncAssertEqual(await eventIterator.next(), .shutdownGracefully)

            await mockService.resumeRunContinuation(with: .success(()))
        }
    }

    func testRun_whenServiceExitsEarly() async throws {
        let configuration = ServiceRunnerConfiguration(gracefulShutdownSignals: [.sigalrm])
        let mockService = MockService(description: "Service1")
        let runner = self.makeServiceRunner(services: [mockService], configuration: configuration)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await runner.run()
            }

            var eventIterator = mockService.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator.next(), .run)

            await mockService.resumeRunContinuation(with: .success(()))

            try await XCTAsyncAssertThrowsError(await group.next()) {
                XCTAssertEqual($0 as? ServiceRunnerError, .serviceFinishedUnexpectedly())
            }
        }
    }

    func testRun_whenServiceExitsEarly_andOtherRunningService() async throws {
        let configuration = ServiceRunnerConfiguration(gracefulShutdownSignals: [.sigalrm])
        let shortService = MockService(description: "Service1")
        let longService = MockService(description: "Service2")
        let runner = self.makeServiceRunner(services: [shortService, longService], configuration: configuration)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await runner.run()
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
                XCTAssertEqual($0 as? ServiceRunnerError, .serviceFinishedUnexpectedly())
            }
        }
    }

    func testRun_whenServiceThrows() async throws {
        let configuration = ServiceRunnerConfiguration(gracefulShutdownSignals: [.sigalrm])
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let runner = self.makeServiceRunner(services: [service1, service2], configuration: configuration)

        try await withThrowingTaskGroup(of: Void.self) { group in
            struct ExampleError: Error, Hashable {}

            group.addTask {
                try await runner.run()
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

    func testGracefulShutdownOrdering() async throws {
        let configuration = ServiceRunnerConfiguration(gracefulShutdownSignals: [.sigalrm])
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let runner = self.makeServiceRunner(services: [service1, service2, service3], configuration: configuration)

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await runner.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            var eventIterator3 = service3.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

            let pid = getpid()
            kill(pid, UnixSignal.sigalrm.rawValue)

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

    func testGracefulShutdownOrdering_whenServiceThrows() async throws {
        let configuration = ServiceRunnerConfiguration(gracefulShutdownSignals: [.sigalrm])
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let runner = self.makeServiceRunner(services: [service1, service2, service3], configuration: configuration)

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await runner.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            var eventIterator3 = service3.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

            let pid = getpid()
            kill(pid, UnixSignal.sigalrm.rawValue)

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
            await service2.resumeRunContinuation(with: .failure(CancellationError()))

            // The first service should now receive a cancellation
            await XCTAsyncAssertEqual(await eventIterator1.next(), .runCancelled)

            // Let's exit from the first service
            await service1.resumeRunContinuation(with: .success(()))
        }
    }

    func testGracefulShutdownOrdering_whenServiceExits() async throws {
        let configuration = ServiceRunnerConfiguration(gracefulShutdownSignals: [.sigalrm])
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let service3 = MockService(description: "Service3")
        let runner = self.makeServiceRunner(services: [service1, service2, service3], configuration: configuration)

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await runner.run()
            }

            var eventIterator1 = service1.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator1.next(), .run)

            var eventIterator2 = service2.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator2.next(), .run)

            var eventIterator3 = service3.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator3.next(), .run)

            let pid = getpid()
            kill(pid, UnixSignal.sigalrm.rawValue)

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

    func testNestedServiceLifecycle() async throws {
        struct NestedRunnerService: Service {
            let runner: ServiceRunner

            init(runner: ServiceRunner) {
                self.runner = runner
            }

            func run() async throws {
                try await self.runner.run()
            }
        }

        let configuration = ServiceRunnerConfiguration(gracefulShutdownSignals: [.sigalrm])
        let service1 = MockService(description: "Service1")
        let service2 = MockService(description: "Service2")
        let nestedRunnerService = NestedRunnerService(
            runner: self.makeServiceRunner(
                services: [service2],
                configuration: .init(gracefulShutdownSignals: [])
            )
        )
        let runner = self.makeServiceRunner(services: [service1, nestedRunnerService], configuration: configuration)

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await runner.run()
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
            kill(pid, UnixSignal.sigalrm.rawValue)
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

    // MARK: - Helpers

    private func makeServiceRunner(
        services: [any Service],
        configuration: ServiceRunnerConfiguration
    ) -> ServiceRunner {
        var logger = Logger(label: "Tests")
        logger.logLevel = .debug

        return .init(
            services: services,
            configuration: configuration,
            logger: logger
        )
    }
}
