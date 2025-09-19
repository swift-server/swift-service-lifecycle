# Adopting ServiceLifecycle in applications

Service Lifecycle provides a unified API for services to streamline their
orchestration in applications: the Service Group actor.

## Overview

Applications often rely on fundamental observability services like logging and
metrics, while long-running actors bundle the application's business logic in
their services. There might also exist HTTP, gRPC, or similar servers exposed by
the application. It is therefore a strong requirement for the application to
orchestrate the various services during startup and shutdown.

With the introduction of Structured Concurrency in Swift, multiple asynchronous
services can be run concurrently with task groups. However, Structured
Concurrency doesn't enforce consistent interfaces between services, and it can
become hard to orchestrate them. To solve this issue, ``ServiceLifecycle``
provides the ``Service`` protocol to enforce a common API, as well as the
``ServiceGroup`` actor to orchestrate all services in an application.

## Adopting the ServiceGroup actor in your application

This article focuses on how ``ServiceGroup`` works, and how you can adopt it in
your application. If you are interested in how to properly implement a service,
go check out the article: <doc:Adopting-ServiceLifecycle-in-libraries>.

### How does the ServiceGroup actor work?

Under the hood, the ``ServiceGroup`` actor is just a complicated task group that
runs each service in a separate child task, and handles individual services
exiting or throwing. It also introduces the concept of graceful shutdown, which
allows the safe teardown of all services in reverse order. Graceful shutdown is
often used in server scenarios, for example when rolling out a new version and
draining traffic from the old version (commonly referred to as quiescing).

### How to use ServiceGroup?

Let's take a look at how ``ServiceGroup`` can be used in an application. First, we
define some fictional services.

```swift
struct FooService: Service {
  func run() async throws { ... }
}

public struct BarService: Service {
  private let fooService: FooService

  init(fooService: FooService) {
    self.fooService = fooService
  }

  func run() async throws { ... }
}
```

In our example, `BarService` depends on `FooService`. A dependency between
services is very common and ``ServiceGroup`` infers the dependencies from the
order that services are passed to in ``ServiceGroup/init(configuration:)``.
Services with a higher index can depend on services with a lower index. The
following example shows how this can be applied to our `BarService`.

```swift
import ServiceLifecycle
import Logging

@main
struct Application {
  static let logger = Logger(label: "Application")

  static func main() async throws {
    let fooService = FooServer()
    let barService = BarService(fooService: fooService)

    let serviceGroup = ServiceGroup(
      // We encode the dependency hierarchy by putting fooService first
      services: [fooService, barService],
      logger: logger
    )

    try await serviceGroup.run()
  }
}
```

### Graceful shutdown

Graceful shutdown is a concept introduced in ServiceLifecycle, with the aim to
be a less forceful alternative to task cancellation. Graceful shutdown allows
each service to opt-in support. For example, you might want to use graceful
shutdown in containerized environments such as Docker or Kubernetes. In those
environments, `SIGTERM` is commonly used to indicate that the application should
shutdown. If it does not, then a `SIGKILL` is sent to force a non-graceful
shutdown.

The ``ServiceGroup`` can be set up to listen to `SIGTERM` and trigger a graceful
shutdown on all its orchestrated services. Once the signal is received, it will
gracefully shut down each service one by one in reverse startup order.
Importantly, the ``ServiceGroup`` is going to wait for the ``Service/run()``
method to return before triggering the graceful shutdown of the next service.

We recommend both application and service authors to make sure that their
implementations handle graceful shutdowns correctly. The following is an example
application that implements a streaming service, but does not support a graceful
shutdown of either the service or application.

```swift
import ServiceLifecycle
import Logging

struct StreamingService: Service {
  struct RequestStream: AsyncSequence { ... }
  struct ResponseWriter {
    func write() 
  }

  private let streamHandler: (RequestStream, ResponseWriter) async -> Void

  init(streamHandler: @escaping (RequestStream, ResponseWriter) async -> Void) {
    self.streamHandler = streamHandler
  }

  func run() async throws {
    await withDiscardingTaskGroup { group in
      for stream in makeStreams() {
        group.addTask {
          await streamHandler(stream.requestStream, stream.responseWriter)
        }
      }
    }
  }
}

@main
struct Application {
  static let logger = Logger(label: "Application")

  static func main() async throws {
    let streamingService = StreamingService(streamHandler: { requestStream, responseWriter in
      for await request in requestStream {
        responseWriter.write("response")
      }
    })

    let serviceGroup = ServiceGroup(
      services: [streamingService],
      gracefulShutdownSignals: [.sigterm],
      logger: logger
    )

    try await serviceGroup.run()
  }
}
```

The code above demonstrates a hypothetical `StreamingService` with one
configurable handler invoked per stream. Each stream is handled concurrently in
a separate child task. The above code doesn't support graceful shutdown right
now, and it has to be added in two places. First, the service's `run()` method
iterates the `makeStream()` async sequence. This iteration is not stopped on a
graceful shutdown, and we continue to accept new streams. Also, the
`streamHandler` that we pass in our main method does not support graceful
shutdown, since it iterates over the incoming requests.

Luckily, adding support in both places is trivial with the helpers that
``ServiceLifecycle`` exposes. In both cases, we iterate over an async sequence
and we want to stop iteration for a graceful shutdown. To do this, we can use
the `cancelOnGracefulShutdown()` method that ``ServiceLifecycle`` adds to
`AsyncSequence`. The updated code looks like this:

```swift
import ServiceLifecycle
import Logging

struct StreamingService: Service {
  struct RequestStream: AsyncSequence { ... }
  struct ResponseWriter {
    func write() 
  }

  private let streamHandler: (RequestStream, ResponseWriter) async -> Void

  init(streamHandler: @escaping (RequestStream, ResponseWriter) async -> Void) {
    self.streamHandler = streamHandler
  }

  func run() async throws {
    await withDiscardingTaskGroup { group in
      for stream in makeStreams().cancelOnGracefulShutdown() {
        group.addTask {
          await streamHandler(stream.requestStream, stream.responseWriter)
        }
      }
    }
  }
}

@main
struct Application {
  static let logger = Logger(label: "Application")

  static func main() async throws {
    let streamingService = StreamingService(streamHandler: { requestStream, responseWriter in
      for await request in requestStream.cancelOnGracefulShutdown() {
        responseWriter.write("response")
      }
    })

    let serviceGroup = ServiceGroup(
      services: [streamingService],
      gracefulShutdownSignals: [.sigterm],,
      logger: logger
    )

    try await serviceGroup.run()
  }
}
```

A valid question to ask here is why we are not using cancellation in the first
place? The problem is that cancellation is forceful and does not allow users to
make a decision if they want to stop a process or not. However, a graceful
shutdown is often very specific to business logic. In our case, we were fine
with just stopping the handling of new requests on a stream. Other applications
might want to send a response to indicate to the client that the server is
shutting down, and await an acknowledgment of that message.

### Customizing the behavior when a service returns or throws

By default, the ``ServiceGroup`` cancels the whole group if one service returns
or throws. However, in some scenarios, this is unexpected, e.g., when the
``ServiceGroup`` is used in a CLI to orchestrate some services while a command
is handled. To customize the behavior, you set the
``ServiceGroupConfiguration/ServiceConfiguration/successTerminationBehavior``
and
``ServiceGroupConfiguration/ServiceConfiguration/failureTerminationBehavior``.
Both of them offer three different options. The default behavior for both is
``ServiceGroupConfiguration/ServiceConfiguration/TerminationBehavior/cancelGroup``.
You can also choose to either ignore that a service returns/throws, by setting
it to
``ServiceGroupConfiguration/ServiceConfiguration/TerminationBehavior/ignore`` or
trigger a graceful shutdown by setting it to
``ServiceGroupConfiguration/ServiceConfiguration/TerminationBehavior/gracefullyShutdownGroup``.

Another example where you might want to customize the behavior is when you
have a service that should be gracefully shut down when another service exits.
For example, you want to make sure your telemetry service is gracefully shut down
after your HTTP server unexpectedly throws from its `run()` method. This setup
could look like this:

```swift
import ServiceLifecycle
import Logging

@main
struct Application {
  static let logger = Logger(label: "Application")

  static func main() async throws {
    let telemetryService = TelemetryService()
    let httpServer = HTTPServer()

    let serviceGroup = ServiceGroup(
      configuration: .init(
        services: [
          .init(service: telemetryService),
          .init(
            service: httpServer, 
            successTerminationBehavior: .shutdownGracefully,
            failureTerminationBehavior: .shutdownGracefully
          )
        ],
        logger: logger
      ),
    )

    try await serviceGroup.run()
  }
}
```
