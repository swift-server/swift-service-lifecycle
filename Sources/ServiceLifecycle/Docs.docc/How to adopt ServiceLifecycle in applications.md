# How to adopt ServiceLifecycle in applications

``ServiceLifecycle`` aims to provide a unified API that services should adopt to
make orchestrating them in an application easier. To achieve this
``ServiceLifecycle`` is providing the ``ServiceGroup`` actor.

## Why do we need this?

When building applications we often have a bunch of services that comprise the
internals of the applications. These services include fundamental needs like
logging or metrics. Moreover, they also include services that comprise the
application's business logic such as long-running actors. Lastly, they might
also include HTTP, gRPC, or similar servers that the application is exposing.
One important requirement of the application is to orchestrate the various
services during startup and shutdown.

Swift introduced Structured Concurrency which already helps tremendously with
running multiple asynchronous services concurrently. This can be achieved with
the use of task groups. However, Structured Concurrency doesn't enforce
consistent interfaces between the services, so it becomes hard to orchestrate
them. This is where ``ServiceLifecycle`` comes in. It provides the ``Service``
protocol which enforces a common API. Additionally, it provides the
``ServiceGroup`` which is responsible for orchestrating all services in an
application.

## Adopting the ServiceGroup in your application

This article is focusing on how the ``ServiceGroup`` works and how you can adopt
it in your application. If you are interested in how to properly implement a
service, go check out the article:
<doc:How-to-adopt-ServiceLifecycle-in-libraries>.

### How is the ServiceGroup working?

The ``ServiceGroup`` is just a complicated task group under the hood that runs
each service in a separate child task. Furthermore, the ``ServiceGroup`` handles
individual services exiting or throwing. Lastly, it also introduces a concept
called graceful shutdown which allows tearing down all services in reverse order
safely. Graceful shutdown is often used in server scenarios i.e. when rolling
out a new version and draining traffic from the old version (commonly referred
to as quiescing).

### How to use the ServiceGroup?

Let's take a look how the ``ServiceGroup`` can be used in an application. First,
we define some fictional services.

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

The `BarService` is depending in our example on the `FooService`. A dependency
between services is quite common and the ``ServiceGroup`` is inferring the
dependencies from the order of the services passed to the
``ServiceGroup/init(configuration:)``. Services with a higher index can depend
on services with a lower index. The following example shows how this can be
applied to our `BarService`.

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
      // We are encoding the dependency hierarchy here by listing the fooService first
      services: [fooService, barService],
      logger: logger
    )

    try await serviceGroup.run()
  }
}
```

### Graceful shutdown

Graceful shutdown is a concept from service lifecycle which aims to be an
alternative to task cancellation that is not as forceful. Graceful shutdown
rather lets the various services opt-in to supporting it. A common example of
when you might want to use graceful shutdown is in containerized enviroments
such as Docker or Kubernetes. In those environments, `SIGTERM` is commonly used
to indicate to the application that it should shut down before a `SIGKILL` is
sent.

The ``ServiceGroup`` can be setup to listen to `SIGTERM` and trigger a graceful
shutdown on all its orchestrated services. It will then gracefully shut down
each service one by one in reverse startup order. Importantly, the
``ServiceGroup`` is going to wait for the ``Service/run()`` method to return
before triggering the graceful shutdown on the next service.

Since graceful shutdown is up to the individual services and application it
requires explicit support. We recommend that every service author makes sure
their implementation is handling graceful shutdown correctly. Lastly,
application authors also have to make sure they are handling graceful shutdown.
A common example of this is for applications that implement streaming
behaviours.

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

The code above demonstrates a hypothetical `StreamingService` with a
configurable handler that is invoked per stream. Each stream is handled in a
separate child task concurrently. The above code doesn't support graceful
shutdown right now. There are two places where we are missing it. First, the
service's `run()` method is iterating the `makeStream()` async sequence. This
iteration is not stopped on graceful shutdown and we are continuing to accept
new streams. Furthermore, the `streamHandler` that we pass in our main method is
also not supporting graceful shutdown since it is iterating over the incoming
requests.

Luckily, adding support in both places is trivial with the helpers that
``ServiceLifecycle`` exposes. In both cases, we are iterating an async sequence
and what we want to do is stop the iteration. To do this we can use the
`cancelOnGracefulShutdown()` method that ``ServiceLifecycle`` adds to
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

Now one could ask - Why aren't we using cancellation in the first place here?
The problem is that cancellation is forceful and doesn't allow users to make a
decision if they want to cancel or not. However, graceful shutdown is very
specific to business logic often. In our case, we were fine with just stopping
to handle new requests on a stream. Other applications might want to send a
response indicating to the client that the server is shutting down and waiting
for an acknowledgment of that message.

### Customizing the behavior when a service returns or throws

By default the ``ServiceGroup`` is cancelling the whole group if the one service
returns or throws. However, in some scenarios this is totally expected e.g. when
the ``ServiceGroup`` is used in a CLI tool to orchestrate some services while a
command is handled. To customize the behavior you set the
``ServiceGroupConfiguration/ServiceConfiguration/successTerminationBehavior`` and
``ServiceGroupConfiguration/ServiceConfiguration/failureTerminationBehavior``. Both of them
offer three different options. The default behavior for both is
``ServiceGroupConfiguration/ServiceConfiguration/TerminationBehavior/cancelGroup``.
You can also choose to either ignore if a service returns/throws by setting it
to ``ServiceGroupConfiguration/ServiceConfiguration/TerminationBehavior/ignore``
or trigger a graceful shutdown by setting it to
``ServiceGroupConfiguration/ServiceConfiguration/TerminationBehavior/gracefullyShutdownGroup``.

Another example where you might want to use this is when you have a service that
should be gracefully shutdown when another service exits, e.g. you want to make
sure your telemetry service is gracefully shutdown after your HTTP server
unexpectedly threw from its `run()` method. This setup could look like this:

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
