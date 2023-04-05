# How to adopt ServiceLifecycle in applications

``ServiceLifecycle`` aims to provide a unified API that services should adopt to make orchestrating
them in an application easier. To achieve this ``ServiceLifecycle`` is providing the ``ServiceRunner`` actor.

## Why do we need this?

When building applications we often have a bunch of services that comprise the internals of the applications.
These services include fundamental needs like logging or metrics. Moreover, they also include
services that compromise the application's business logic such as long-running actors.
Lastly, they might also include HTTP, gRPC, or similar servers that the application is exposing.
One important requirement of the application is to orchestrate the various services currently during
startup and shutdown. Furthermore, the application also needs to handle a single service failing.

Swift introduced Structured Concurrency which already helps tremendously with running multiple 
async services concurrently. This can be achieved with the use of task groups. However, Structured
Concurrency doesn't enforce consistent interfaces between the services, so it becomes hard to orchestrate them.
This is where ``ServiceLifecycle`` comes in. It provides the ``Service`` protocol which enforces 
a common API. Additionally, it provides the ``ServiceRunner`` which is responsible for orchestrating
all services in an application.

## Adopting the ServiceRunner in your application

This article is focusing on how the ``ServiceRunner`` works and how you can adopt it in your application.
If you are interested in how to properly implement a service, go check out the article:  <doc:How-to-adopt-ServiceLifecycle-in-libraries>.

### How is the ServiceRunner working?

The ``ServiceRunner`` is just a slightly complicated task group under the hood that runs each service
in a separate child task. Furthermore, the ``ServiceRunner`` handles individual services exiting
or throwing unexpectedly. Lastly, it also introduces a concept called graceful shutdown which allows
tearing down all services in reverse order safely. Graceful shutdown is often used in server
scenarios i.e. when rolling out a new version and draining traffic from the old version.

### How to use the ServiceRunner?

Let's take a look how the ``ServiceRunner`` can be used in an application. First, we define some
fictional services.

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

The `BarService` is depending in our example on the `FooService`. A dependency between services
is quite common and the ``ServiceRunner`` is inferring the dependencies from the order of the 
services passed to the ``ServiceRunner/init(services:configuration:logger:)``. Services with a higher
index can depend on services with a lower index. The following example shows how this can be applied
to our `BarService`.

```swift
@main
struct Application {
  static func main() async throws {
    let fooService = FooServer()
    let barService = BarService(fooService: fooService)

    let serviceRunner = ServiceRunner(
      // We are encoding the dependency hierarchy here by listing the fooService first
      services: [fooService, barService],
      configuration: .init(gracefulShutdownSignals: []),
      logger: logger
    )

    try await serviceRunner.run()
  }
}
```

### Graceful shutdown

The ``ServiceRunner`` supports graceful shutdown by taking an array of `UnixSignal`s that trigger
the shutdown. Commonly `SIGTERM` is used to indicate graceful shutdowns in container environments 
such as Docker or Kubernetes. The ``ServiceRunner`` is then gracefully shutting down each service
one by one in the reverse order of the array passed to the init.
Importantly, the ``ServiceRunner`` is going to wait for the ``Service/run()`` method to return
before triggering the graceful shutdown on the next service.

Since graceful shutdown is up to the individual services and application it requires explicit support.
We recommend that every service author makes sure their implementation is handling graceful shutdown
correctly. Lastly, application authors also have to make sure they are handling graceful shutdown.
A common example of this is for applications that implement streaming behaviours.

```swift
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
      group.addTask {
        for stream in makeStreams() {
          await streamHandler(stream.requestStream, stream.responseWriter)
        }
      }
    }
  }
}

@main
struct Application {
  static func main() async throws {
    let streamingService = StreamingService(streamHandler: { requestStream, responseWriter in
      for await request in requestStream {
        responseWriter.write("response")
      }
    })

    let serviceRunner = ServiceRunner(
      services: [streamingService],
      configuration: .init(gracefulShutdownSignals: [.sigterm]),
      logger: logger
    )

    try await serviceRunner.run()
  }
}
```

The code above demonstrates a hypothetical `StreamingService` with a configurable handler that
is invoked per stream. Each stream is handled in a separate child task concurrently.
The above code doesn't support graceful shutdown right now. There are two places where we are missing it.
First, the service's `run()` method is iterating the `makeStream()` async sequence. This iteration is
not stopped on graceful shutdown and we are continuing to accept new streams. Furthermore, 
the `streamHandler` that we pass in our main method is also not supporting graceful shutdown since it
is iterating over the incoming requests.

Luckily, adding support in both places is trivial with the helpers that ``ServiceLifecycle`` exposes.
In both cases, we are iterating an async sequence and what we want to do is stop the iteration.
To do this we can use the `cancelOnGracefulShutdown()` method that ``ServiceLifecycle`` adds to
`AsyncSequence`. The updated code looks like this:

```swift
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
      group.addTask {
        for stream in makeStreams().cancelOnGracefulShutdown() {
          await streamHandler(stream.requestStream, stream.responseWriter)
        }
      }
    }
  }
}

@main
struct Application {
  static func main() async throws {
    let streamingService = StreamingService(streamHandler: { requestStream, responseWriter in
      for await request in requestStream.cancelOnGracefulShutdown() {
        responseWriter.write("response")
      }
    })

    let serviceRunner = ServiceRunner(
      services: [streamingService],
      configuration: .init(gracefulShutdownSignals: [.sigterm]),
      logger: logger
    )

    try await serviceRunner.run()
  }
}
```

Now one could ask - Why aren't we using cancellation in the first place here? The problem is that
cancellation is forceful and doesn't allow users to make a decision if they want to cancel or not.
However, graceful shutdown is very specific to business logic often. In our case, we were fine with just
stopping to handle new requests on a stream. Other applications might want to send a response indicating
to the client that the server is shutting down and waiting for an acknowledgment of that message.
