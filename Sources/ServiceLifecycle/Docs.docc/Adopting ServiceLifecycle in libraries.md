# Adopting ServiceLifecycle in libraries

Adopt the Service protocol for your service to allow a Service Group to coordinate it's operation with other services.

## Overview

Service Lifecycle provides a unified API to represent a long running task: the ``Service`` protocol.

Before diving into how to adopt this protocol in your library, let's take a step back and talk about why we need to have this unified API.
Services often need to schedule long-running tasks, such as sending keep-alive pings in the background, or the handling of incoming work like new TCP connections.
Before Swift Concurrency was introduced, services put their work into separate threads using a `DispatchQueue` or an NIO `EventLoop`.
Services often required explicit lifetime management to make sure their resources, such as threads, were shut down correctly.

With the introduction of Swift Concurrency, specifically by using Structured Concurrency, we have better tools to structure our programs and model our work as a tree of tasks.
The `Service` protocol provides a common interface, a single `run()` method, for services to use when they run  their long-running work.
If all services in an application conform to this protocol, then orchestrating them becomes trivial.

## Adopting the Service protocol in your service

Adopting the `Service` protocol is quite easy.
The protocol's single requirement is the ``Service/run()`` method.
Make sure that your service adheres to the important caveats addressed in the following sections.

### Use Structured Concurrency

Swift offers multiple ways to use Concurrency.
The primary primitives are the `async` and `await` keywords which enable straight-line code to make asynchronous calls.
The language also provides the concept of task groups; they allow the creation of concurrent work, while staying tied to the parent task.
At the same time, Swift also provides `Task(priority:operation:)` and `Task.detached(priority:operation:)` which create new unstructured Tasks.

Imagine our library wants to offer a simple `TCPEchoClient`.
To make it Interesting, let's assume we need to send keep-alive pings on every open connection every second.
Below you can see how we could implement this using unstructured concurrency.

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

The above code has a few problems.
First, the code never cancels the `Task` that runs the keep-alive pings.
To do this, it would need to store the `Task` in the actor and cancel it at the appropriate time.
Second, it would also need to expose a `cancel()` method on the actor to cancel the `Task`.
If it were to do all of this, it would have reinvented Structured Concurrency.

To avoid all of these problems, the code can conform to the ``Service`` protocol.
Its requirement guides us to implement the long-running work inside the `run()` method.
It allows the user of the client to decide in which task to schedule the keep-alive pings — using an unstructured `Task` is an option as well.
Furthermore, we now benefit from the automatic cancellation propagation by the task that called our `run()` method.
The code below illustrates an overhauled implementation that exposes such a `run()` method:

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

Since the `run()` method contains long-running work, returning from it is interpreted as a failure and will lead to the ``ServiceGroup`` canceling all other services.
Unless specified otherwise in
``ServiceGroupConfiguration/ServiceConfiguration/successTerminationBehavior``
and
``ServiceGroupConfiguration/ServiceConfiguration/failureTerminationBehavior``,
each task started in its respective `run()` method will be canceled.

### Cancellation

Structured Concurrency propagates task cancellation down the task tree.
Every task in the tree can check for cancellation or react to it with cancellation handlers.
``ServiceGroup`` uses task cancellation to tear down everything when a service’s `run()` method returns early or throws an error.
Hence, it is important that each service properly implements task cancellation in their `run()` methods.

Note: If your `run()` method calls other async methods that support cancellation, or consumes an `AsyncSequence`, then you don't have to do anything explicitly.
The latter is shown in the `TCPEchoClient` example above.

### Graceful shutdown

Applications are often required to be shut down gracefully when run in a real production environment.

For example, the application might be deployed on Kubernetes and a new version got released.
During a rollout of that new version, Kubernetes sends a `SIGTERM` signal to the application, expecting it to terminate within a grace period.
If the application does not stop in time, then Kubernetes sends the `SIGKILL` signal and forcefully terminates the process.
For this reason, ``ServiceLifecycle`` introduces the _shutdown gracefully_ concept that allows terminating an application’s work in a structured and graceful manner.
This behavior is similar to task cancellation, but due to its opt-in nature, it is up to the business logic of the application to decide what to do.

``ServiceLifecycle`` exposes one free function called ``withGracefulShutdownHandler(operation:onGracefulShutdown:)`` that works similarly to the `withTaskCancellationHandler` function from the Concurrency library.
Library authors are expected to make sure that any work they spawn from the `run()` method properly supports graceful shutdown.
For example, a server might close its listening socket to stop accepting new connections.
It is of upmost importance that the server does not force the closure of any currently open connections.
It is expected that the business logic behind these connections handles the graceful shutdown.

An example high-level implementation of a `TCPEchoServer` with graceful shutdown
support might look like this:

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

When the above code receives the graceful shutdown sequence, the only reasonable thing for `TCPEchoClient` to do is cancel the iteration of the timer sequence.
``ServiceLifecycle`` provides a convenience on `AsyncSequence` to cancel on graceful shutdown.
Let's take a look at how this works.

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

As you can see in the code above, the additional `cancelOnGracefulShutdown()` call takes care of any downstream cancellation.
