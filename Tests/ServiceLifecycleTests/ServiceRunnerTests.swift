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

    let isLongRunning: Bool

    let events: AsyncStream<Event>

    private let eventsContinuation: AsyncStream<Event>.Continuation

    private var runContinuation: CheckedContinuation<Void, Error>?

    private var shutdownGracefullyContinuation: CheckedContinuation<Void, Error>?

    nonisolated let description: String

    init(
        isLongRunning: Bool,
        description: String
    ) {
        self.isLongRunning = isLongRunning
        var continuation: AsyncStream<Event>.Continuation!
        self.events = AsyncStream<Event> { continuation = $0 }
        self.eventsContinuation = continuation!
        self.description = description
    }

    func run() async throws {
        self.eventsContinuation.yield(.run)
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while true {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        self.eventsContinuation.yield(.runPing)
                    }
                }

                try await withCheckedThrowingContinuation {
                    self.runContinuation = $0
                }

                group.cancelAll()
            }
        } onCancel: {
            self.eventsContinuation.yield(.runCancelled)
        }
    }

    func shutdownGracefully() async throws {
        self.eventsContinuation.yield(.shutdownGracefully)

        try await withCheckedThrowingContinuation {
            self.shutdownGracefullyContinuation = $0
        }
    }

    func resumeRunContinuation(with result: Result<Void, Error>) {
        self.runContinuation?.resume(with: result)
    }

    func resumeShutdownGracefullyContinuation(with result: Result<Void, Error>) {
        self.shutdownGracefullyContinuation?.resume(with: result)
    }
}

final class ServiceRunnerTests: XCTestCase {
    func testRun_whenAlreadyRunning() async throws {
        let mockService = MockService(isLongRunning: true, description: "Service1")
        let runner = self.makeServiceRunner(services: [mockService], configuration: .init())

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
        let runner = self.makeServiceRunner(services: [], configuration: .init())

        try await runner.run()

        try await XCTAsyncAssertThrowsError(await runner.run()) {
            XCTAssertEqual($0 as? ServiceRunnerError, .alreadyFinished())
        }
    }

    func testRun_whenNoService_andNoSignal() async throws {
        let runner = self.makeServiceRunner(services: [], configuration: .init())

        try await runner.run()
    }

    func testRun_whenNoSignal() async throws {
        let mockService = MockService(isLongRunning: true, description: "Service1")
        let runner = self.makeServiceRunner(services: [mockService], configuration: .init())

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
        let mockService = MockService(isLongRunning: true, description: "Service1")
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
            await mockService.resumeShutdownGracefullyContinuation(with: .success(()))
        }
    }

    func testRun_whenServiceExitsEarly_andLongRunning() async throws {
        let configuration = ServiceRunnerConfiguration(gracefulShutdownSignals: [.sigalrm])
        let mockService = MockService(isLongRunning: true, description: "Service1")
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

    func testRun_whenServiceExitsEarly_andNotLongRunning() async throws {
        let configuration = ServiceRunnerConfiguration(gracefulShutdownSignals: [.sigalrm])
        let mockService = MockService(isLongRunning: false, description: "Service1")
        let runner = self.makeServiceRunner(services: [mockService], configuration: configuration)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await runner.run()
            }

            var eventIterator = mockService.events.makeAsyncIterator()
            await XCTAsyncAssertEqual(await eventIterator.next(), .run)

            await mockService.resumeRunContinuation(with: .success(()))

            await XCTAssertNoThrow(try await group.next())
        }
    }

    func testRun_whenServiceExitsEarly_andOtherLongRunningService() async throws {
        let configuration = ServiceRunnerConfiguration(gracefulShutdownSignals: [.sigalrm])
        let shortService = MockService(isLongRunning: false, description: "Service1")
        let longService = MockService(isLongRunning: true, description: "Service2")
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
            await XCTAsyncAssertEqual(await longServiceEventIterator.next(), .runPing)
            // Finishing the long running service here
            await longService.resumeRunContinuation(with: .success(()))

            try await XCTAsyncAssertThrowsError(await group.next()) {
                XCTAssertEqual($0 as? ServiceRunnerError, .serviceFinishedUnexpectedly())
            }
        }
    }

    func testRun_whenServiceThrows() async throws {
        let configuration = ServiceRunnerConfiguration(gracefulShutdownSignals: [.sigalrm])
        let service1 = MockService(isLongRunning: true, description: "Service1")
        let service2 = MockService(isLongRunning: true, description: "Service2")
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

    func testRun_whenShuttingDownGracefullyThrows() async throws {
        let configuration = ServiceRunnerConfiguration(gracefulShutdownSignals: [.sigalrm])
        let service1 = MockService(isLongRunning: true, description: "Service1")
        let service2 = MockService(isLongRunning: true, description: "Service2")
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
            await XCTAsyncAssertEqual(await service1EventIterator.next(), .runPing)
            await XCTAsyncAssertEqual(await service2EventIterator.next(), .runPing)

            let pid = getpid()
            kill(pid, UnixSignal.sigalrm.rawValue)
            await XCTAsyncAssertEqual(await service2EventIterator.next(), .shutdownGracefully)

            await service2.resumeShutdownGracefullyContinuation(with: .failure(ExampleError()))

            await XCTAsyncAssertEqual(await service1EventIterator.next(), .runCancelled)

            await service1.resumeRunContinuation(with: .success(()))
            await service2.resumeRunContinuation(with: .success(()))

            try await XCTAsyncAssertThrowsError(await group.next()) {
                XCTAssertTrue($0 is ExampleError)
            }
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

private func XCTAsyncAssertEqual<T>(
    _ expression1: @autoclosure () async throws -> T,
    _ expression2: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async rethrows where T: Equatable {
    let result1 = try await expression1()
    let result2 = try await expression2()
    XCTAssertEqual(result1, result2, message(), file: file, line: line)
}

private func XCTAsyncAssertThrowsError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (_ error: Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

private func XCTAssertNoThrow<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
    } catch {
        XCTFail("Threw error \(error)", file: file, line: line)
    }
}
