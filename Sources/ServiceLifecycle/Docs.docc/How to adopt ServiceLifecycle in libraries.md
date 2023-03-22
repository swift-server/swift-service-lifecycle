# How to adopt ServiceLifecycle in libraries

``ServiceLifecycle`` aims to provide a unified API that services should adopt to make orchestrating
them in an application easier. To achieve this ``ServiceLifecycle`` is providing the ``Service`` protocol.

## Why do we need this?

Before diving into how to adopt this protocol in your library, let's take a step back and
talk about why we even need to have this unified API. A common need for services is to either
schedule long running work like sending keep alive pings in the background or to handle new
incoming work like handling new TCP connections. Before Concurrency was introduced services put
their work into separate threads using things like `DispatchQueue`s or NIO `EventLoop`s.
This often required explicit lifetime management of the services to make sure to shutdown the threads correctly.
With the introduction of Concurrency, specifically Structured Concurrency, we now have a better way
to structure our programs and model our work as a tree of tasks.
The ``Service`` protocol is providing a common interface that requires a single `run()` method where
services can put their long running work in. Having all services in an application conform to this
protocol enables easy orchestration of them and makes sure they interact nicely with each other.

## Adopting the Service protocol in your service

Adopting the ``Service`` protocol is quite easy in your services. The protocol has only a single requirement
which is the ``Service/run()`` method. There are a few important caveats to it which we are going over in the
next sections. Make sure that your service is following those.

### Make sure to use Structured Concurrency

Swift offers multiple ways to use Structured Concurrency. The primary primitives are the
`async` and `await` keywords which enable straight-line code to make asynchronous calls.
Furthermore, the language provides the concept of task groups which allow the creation of 
concurrent work while still staying tied to the parent task. On the other hand, Swift also provides
`Task(priority:operation:)` and `Task.detached(priority:operation:)` which create a new unstructured Task.

Imagine our library wants to offer a simple `TCPEchoClient`. To make it interesting let's assume we 
need to send keep-alive pings on every open connection every second. Below you can see how we could 
implement this using unstructured Concurrency.

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

The above code has a few problems. First, we are never canceling the `Task` that is running the 
keep-alive pings. To do this we would need to store the `Task` in our actor and cancel it at the 
appropriate time. Secondly, we actually would need to expose a `cancel()` method on the actor to cancel
the `Task`. At this point, we have just reinvented Structured Concurrency.
To avoid all of these problems we can just conform to the ``Service`` protocol which requires a `run()`
method. This requirement already guides us to implement the long running work inside the `run()` method.
Having this method allows the user of the client to decide in which task to schedule the keep-alive pings.
They can still decide to create an unstructured `Task` for this, but that is up to the user now. 
Furthermore, we now get automatic cancellation propagation from the task that called our `run()` method.
Below is an overhauled implementation that exposes such a `run()` method.

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

Since the `run()` method contains long running work, returning from it is seen as a failure and will
lead to the ``ServiceRunner`` cancelling all other services by cancelling the task that is running
their respective `run()` method.

### Cancellation

Structured Concurrency propagates task cancellation down the task tree. Every task in the tree can
check for cancellation or react to it with cancellation handlers. The ``ServiceRunner`` is using task
cancellation to tear everything down in the case of an early return or thrown error from the `run()`
method of any of the services. Hence it is important that each service properly implements task
cancellation in their `run()` methods.

Note: If your `run()` method is only calling other async methods that support cancellation themselves
or is consuming an `AsyncSequence`, you don't have to do anything explicitly here. Looking at the
`TCPEchoClient` example from above we can see that we only call `Task.sleep` in our `run()` method
which is supporting task cancellation.

### Graceful shutdown

When running an application in a real environment it is often required to gracefully shutdown the application.
For example, the application might be running in Kubernetes and a new version of it got deployed. In this
case, Kubernetes is going to send a `SIGTERM` signal to the application and expects it to terminate
within a grace period. If the application isn't stopping in time then Kubernetes will send the `SIGKILL`
signal and forcefully terminate the process.
For this reason ``ServiceLifecycle`` introduces a new _shutdown gracefully_ concept that allows terminating
the work in a structured and graceful manner. This works similarly to task cancellation but
it is fully opt-in and up to the business logic of the application to decide what to do.

``ServiceLifecycle`` exposes one free function called ``withShutdownGracefulHandler(operation:onGracefulShutdown:)``
that works similarly to the `withTaskCancellationHandler` function from the Concurrency library.
Library authors are expected to make sure that any work they spawn from the `run()` method 
properly supports graceful shutdown. For example, a server might be closing its listening socket
to stop accepting new connections.
Importantly here though is that the server is not force closing the currently open ones. Rather it 
expects the business logic on these connections to handle graceful shutdown on their own.

An example implementation of a `TCPEchoServer` on a high level that supports graceful shutdown
might look like this.

```swift
public actor TCPEchoClient: Service {
  public init() { }

  public func run() async throws {
    await withShutdownGracefulHandler {
        for connection in self.listeningSocket.connections {
          // Handle incoming connections
        }
    } onGracefulShutdown: {
        self.listeningSocket.close()
    }
  }
}
````

In the case of our `TCPEchoClient`, the only reasonable thing to do is cancel the iteration of our
timer sequence when we receive the graceful shutdown sequence. ``ServiceLifecycle`` is providing
a convenience on `AsyncSequence` to cancel on graceful shutdown. Let's take a look at how this works.

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

As you can see in the code above, it is as simple as adding a `cancelOnGracefulShutdown()` call.
