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

import ServiceLifecycle

actor MockService: Service, CustomStringConvertible {
    enum Event {
        case run
        case runPing
        case runCancelled
        case shutdownGracefully
    }

    let events: AsyncStream<Event>
    private(set) var hasRun: Bool = false

    private let eventsContinuation: AsyncStream<Event>.Continuation

    private var runContinuation: CheckedContinuation<Void, Error>?

    nonisolated let description: String

    private let pings: AsyncStream<Void>
    private nonisolated let pingContinuation: AsyncStream<Void>.Continuation

    init(
        description: String
    ) {
        var eventsContinuation: AsyncStream<Event>.Continuation!
        events = AsyncStream<Event> { eventsContinuation = $0 }
        self.eventsContinuation = eventsContinuation!

        var pingContinuation: AsyncStream<Void>.Continuation!
        pings = AsyncStream<Void> { pingContinuation = $0 }
        self.pingContinuation = pingContinuation!

        self.description = description
    }

    func run() async throws {
        hasRun = true

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
        runContinuation?.resume(with: result)
    }

    nonisolated func sendPing() {
        pingContinuation.yield()
    }
}
