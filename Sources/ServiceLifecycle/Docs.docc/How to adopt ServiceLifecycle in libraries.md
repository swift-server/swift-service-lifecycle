# How to adopt ServiceLifecycle in libraries

``ServiceLifecycle`` provides a unified API for services to streamline their
orchestration in libraries: the ``Service`` protocol.

## Why do we need this?

Before diving into how to adopt this protocol in your library, let's take a step
back and talk about why we even need to have this unified API. Services often
need to schedule long running tasks, such as sending keep alive pings in the
background, or the handling of incoming work like new TCP connections. Before
Concurrency was introduced, services put their work into separate threads using
`DispatchQueue`s or NIO `EventLoop`s. Services often required explicit lifetime
management to make sure their resources, e.g. threads, were shutdown correctly.
With the introduction of Concurrency, specifically Structured Concurrency, we
have better tools to structure our programs and model our work as a tree of
tasks. The ``Service`` protocol provides a common interface, a single `run()`
method, for services to put their long running work into. If all services in an
application conform to this protocol, then their orchestration and interaction
with each other becomes trivial.

## Adopting the Service protocol in your service

Adopting the ``Service`` protocol is quite easy. The protocol's single
requirement is the ``Service/run()`` method. Make sure that your service adheres
to the important caveats that we are going to address in the following sections.

### Use Structured Concurrency

Swift offers multiple ways to use Structured Concurrency. The primary primitives
are the `async` and `await` keywords which enable straight-line code to make
asynchronous calls. The language also provides the concept of task groups: they
allow the creation of concurrent work, while staying tied to the parent task. At
the same time, Swift also provides `Task(priority:operation:)` and
`Task.detached(priority:operation:)` which create a new unstructured Task.

Imagine our library wants to offer a simple `TCPEchoClient`. To make it
interesting let's assume we need to send keep-alive pings on every open
connection every second. Below you can see how we could implement this using
unstructured Concurrency.

```swift
public actor TCPEchoClient {
  public init() {
    Task {
      for await _ in AsyncTimerSequence(interval: .seconds(1), clock: .continuous) {
        self.sendKeepAlivePings()
      }
    }
  }

  private func sendKeepAlivePings() async { ... }
}
```

The above code has a few problems. First, we never cancel the `Task` that runs
the keep-alive pings. To do this, we would need to store the `Task` in our actor
and cancel it at the appropriate time. Second, we would also need to expose a
`cancel()` method on the actor to cancel the `Task`. If we were to do this, we
would have reinvented Structured Concurrency.

To avoid all of these problems, we can conform to the ``Service`` protocol. Its
requirement guides us to implement the long running work inside the `run()`
method. It allows the user of the client to decide in which task to schedule the
keep-alive pings—unstructured `Task` are an option as well. Furthermore, we now
benefit from automatic cancellation propagation by the task that called our
`run()` method. Below you can find an overhauled implementation exposing such a
`run()` method.

```swift
public actor TCPEchoClient: Service {
  public init() { }

  public func run() async throws {
    for await _ in AsyncTimerSequence(interval: .seconds(1), clock: .continuous) {
      self.sendKeepAlivePings()
    }
  }

  private func sendKeepAlivePings() async { ... }
}
```

### Returning from your `run()` method

Since the `run()` method contains long running work, returning from it is seen
as a failure and will lead to the ``ServiceGroup`` canceling all other services.
Unless specified otherwise in
``ServiceGroupConfiguration/ServiceConfiguration/successTerminationBehavior``
and
``ServiceGroupConfiguration/ServiceConfiguration/failureTerminationBehavior``,
each task started in the respective `run()` method will be canceled.

### Cancellation

Structured Concurrency propagates task cancellation down the task tree. Every
task in the tree can check for cancellation or react to it with cancellation
handlers. ``ServiceGroup`` uses task cancellation to tear down everything when a
services' `run() method` returns early or throws an error. Hence it is important
that each service properly implements task cancellation in their `run()`
methods.

Note: If your `run()` method calls other async methods that support
cancellation, or consumes an `AsyncSequence`, then you don't have to do anything
explicitly. The latter is shown in the `TCPEchoClient` example above.

### Graceful shutdown

Applications are often required to be shutdown gracefully when run in a real
production environment.

For example, the application might be deployed on Kubernetes and a new version
got released. During a rollout of that new version, Kubernetes is going to send
a `SIGTERM` signal to the application, expecting it to terminate within a grace
period. If the application does not stop in time, then Kubernetes will send the
`SIGKILL` signal and forcefully terminate the process. For this reason
``ServiceLifecycle`` introduces the _shutdown gracefully_ concept that allows
terminating an applications' work in a structured and graceful manner. This
behavior is similar to task cancellation, but due to its opt-in nature it is up
to the business logic of the application to decide what to do.

``ServiceLifecycle`` exposes one free function called
``withGracefulShutdownHandler(operation:onGracefulShutdown:)`` that works
similarly to the `withTaskCancellationHandler` function from the Concurrency
library. Library authors are expected to make sure that any work they spawn from
the `run()` method properly supports graceful shutdown. For example, a server
might close its listening socket to stop accepting new connections. It is of
upmost importance that the server does not force the closure of any currently
open connections. It is expected that the business logic behind these
connections handles the graceful shutdown.

An example high level implementation of a `TCPEchoServer` with graceful shutdown
support might look like this.

```swift
public actor TCPEchoServer: Service {
  public init() { }

  public func run() async throws {
    await withGracefulShutdownHandler {
        for connection in self.listeningSocket.connections {
          // Handle incoming connections
        }
    } onGracefulShutdown: {
        self.listeningSocket.close()
    }
  }
}
```

When we receive the graceful shutdown sequence, the only reasonable thing for
`TCPEchoClient` to do is cancel the iteration of the timer sequence.
``ServiceLifecycle`` provides a convenience on `AsyncSequence` to cancel on
graceful shutdown. Let's take a look at how this works.

```swift
public actor TCPEchoClient: Service {
  public init() { }

  public func run() async throws {
    for await _ in AsyncTimerSequence(interval: .seconds(1), clock: .continuous).cancelOnGracefulShutdown() {
      self.sendKeepAlivePings()
    }
  }

  private func sendKeepAlivePings() async { ... }
}
```

As you can see in the code above, the additional `cancelOnGracefulShutdown()`
call takes care of any downstream cancellation.
