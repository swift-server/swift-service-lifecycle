# Swift Service Lifecycle

Swift Service Lifecycle provides a basic mechanism to cleanly start up and shut down the application, freeing resources in order before exiting.
It also provides a `Signal`-based shutdown hook, to shut down on signals like `TERM` or `INT`.

Swift Service Lifecycle was designed with the idea that every application has some startup and shutdown workflow-like-logic which is often sensitive to failure and hard to get right.
The library codes this common need in a safe and reusable way that is non-framework specific, and designed to be integrated with any server framework or directly in an application.

This is the beginning of a community-driven open-source project actively seeking [contributions](CONTRIBUTING.md), be it code, documentation, or ideas. What Swift Service Lifecycle provides today is covered in the [API docs](https://swift-server.github.io/swift-service-lifecycle/), but it will continue to evolve with community input.

## Getting started

If you have a server-side Swift application or a cross-platform (e.g. Linux, macOS) application, and you would like to manage its startup and shutdown lifecycle, Swift Service Lifecycle is a great idea. Below you will find all you need to know to get started.

### Adding the dependency

To add a dependency on the package, declare it in your `Package.swift`:

```swift
.package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "1.0.0-alpha"),
```

and to your application target, add `Lifecycle` to your dependencies:

```swift
.target(name: "MyApplication", dependencies: [.product(name: "Lifecycle", package: "swift-service-lifecycle")]),
```

###  Defining the lifecycle

```swift
// import the package
import Lifecycle

// initialize the lifecycle container
let lifecycle = ServiceLifecycle()

// register a resource that should be shut down when the application exits.
//
// in this case, we are registering a SwiftNIO `EventLoopGroup`
// and passing its `syncShutdownGracefully` function to be called on shutdown
let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
lifecycle.registerShutdown(
    label: "eventLoopGroup",
    .sync(eventLoopGroup.syncShutdownGracefully)
)

// register another resource that should be started when the application starts
// and shut down when the application exits.
//
// in this case, we are registering a contrived `DatabaseMigrator`
// and passing its `migrate` function to be called on startup
// and `shutdown` function to be called on shutdown
let migrator = DatabaseMigrator()
lifecycle.register(
    label: "migrator",
    start: .async(migrator.migrate),
    shutdown: .async(migrator.shutdown)
)

// start the application
//
// start handlers passed using the `register` function
// will be called in the order they were registered in
lifecycle.start { error in
    // start completion handler.
    // if a startup error occurred you can capture it here
    if let error = error {
        logger.error("failed starting \(self) ☠️: \(error)")
    } else {
        logger.info("\(self) started successfully 🚀")
    }
}
// wait for the application to exit
//
// this is a blocking operation that typically waits for a signal
// the signal can be configured at `lifecycle.start`, and defaults to `INT` and `TERM`
// shutdown handlers passed using the `register` or `registerShutdown` functions
// will be called in the reverse order they were registered in
lifecycle.wait()
```

## Detailed design

The main types in the library are `ServiceLifecycle` and `ComponentLifecycle`.

`ServiceLifecycle` is the most commonly used type.
It is designed to manage the top-level Application (Service) lifecycle,
and in addition to managing the startup and shutdown flows it can also set up `Signal` trap for shutdown and install backtraces.

`ComponentLifecycle` manages a state machine representing the startup and shutdown logic flow.
In larger Applications (Services) `ComponentLifecycle` can be used to manage the lifecycle of subsystems, such that `ServiceLifecycle` can start and shutdown `ComponentLifecycle`s.

### Registering items

`ServiceLifecycle` and `ComponentLifecycle` are containers for `LifecycleTask`s which need to be registered using a `LifecycleHandler` - a container for synchronous or asynchronous closures.

Synchronous handlers are defined as  `() throws -> Void`.

Asynchronous handlers defined are as  `(@escaping (Error?) -> Void) -> Void`.

`LifecycleHandler` comes with static helpers named `async` and `sync` designed to help simplify the registration call to:

```swift
let foo = ...
lifecycle.register(
    label: "foo",
    start: .sync(foo.syncStart),
    shutdown: .sync(foo.syncShutdown)
)
```

Or the async version:

```swift
let foo = ...
lifecycle.register(
    label: "foo",
    start: .async(foo.asyncStart),
    shutdown: .async(foo.asyncShutdown)
)
```

or, just shutdown:

```swift
let foo = ...
lifecycle.registerShutdown(
    label: "foo",
    .sync(foo.syncShutdown)
)
```
Or the async version:

```swift
let foo = ...
lifecycle.registerShutdown(
    label: "foo",
    .async(foo.asyncShutdown)
)
```

you can also register a collection of `LifecycleTask`s (less typical) using:

```swift
func register(_ tasks: [LifecycleTask])

func register(_ tasks: LifecycleTask...)
```

### Configuration

`ServiceLifecycle` initializer takes optional `ServiceLifecycle.Configuration` to further refine the `ServiceLifecycle` behavior:

* `logger`: Defines the `Logger` to work with.  By default, `Logger(label: "Lifecycle")` is used.

* `callbackQueue`: Defines the `DispatchQueue` on which startup and shutdown handlers are executed. By default, `DispatchQueue.global` is used.

* `shutdownSignal`: Defines what, if any, signals to trap for invoking shutdown. By default, `INT` and `TERM` are trapped.

* `installBacktrace`: Defines if to install a crash signal trap that prints backtraces. This is especially useful for applications running on Linux since Swift does not provide backtraces on Linux out of the box. This functionality is provided via the [Swift Backtrace](https://github.com/swift-server/swift-backtrace) library.

### Starting the lifecycle

Use the `start` function to start the application.
Start handlers passed using the `register` function will be called in the order the items were registered in.

`start` is an asynchronous operation.
If a startup error occurred, it will be logged and the startup sequence will halt on the first error, and bubble it up to the provided completion handler.

```swift
lifecycle.start { error in
    if let error = error {
        logger.error("failed starting \(self) ☠️: \(error)")
    } else {
        logger.info("\(self) started successfully 🚀")
    }
}
```

### Shutdown

The typical use of the library is to call on `wait` after calling `start`.

```swift
lifecycle.start { error in
  ...   
}
lifecycle.wait() // <-- blocks the thread
```

If you are not interested in handling start completion, there is also a convenience method:

```swift
lifecycle.startAndWait() // <-- blocks the thread
```

Both `wait` and `startAndWait` are blocking operations that wait for the lifecycle library to finish the shutdown sequence.
The shutdown sequence is typically triggered by the `shutdownSignal` defined in the configuration. By default, `INT` and `TERM` are trapped.

During shutdown, the shutdown handlers passed using the `register` or `registerShutdown` functions are called in the reverse order of the registration. E.g.

```
lifecycle.register("1", ...)
lifecycle.register("2", ...)
lifecycle.register("3", ...)
```

startup order will be 1, 2, 3 and shutdown order will be 3, 2, 1.

If a shutdown error occurred, it will be logged and the shutdown sequence will *continue* to the next item, and attempt to shut it down until all registered items that have been started are shut down.

In more complex cases, when `Signal`-trapping-based shutdown is not appropriate, you may pass `nil` as the `shutdownSignal` configuration, and call `shutdown` manually when appropriate. This is designed to be a rarely used pressure valve.

`shutdown` is an asynchronous operation. Errors will be logged and bubbled up to the provided completion handler.

### Stateful handlers

In some cases it is useful to have the Start handlers return a state that can be passed on to the Shutdown handlers for shutdown.
For example, when establishing some sort of a connection that needs to be closed at shutdown.

```swift
struct Foo {
  func start() throws -> Connection {
      return ...
  }

  func shutdown(state: Connection) throws {
      ...
  }
}
```

```swift
let foo = ...
lifecycle.registerStateful(
    label: "foo",
    start: .sync(foo.start),
    shutdown: .sync(foo.shutdown)
)
```

### Complex Systems and Nesting of Subsystems

In larger Applications (Services) `ComponentLifecycle` can be used to manage the lifecycle of subsystems, such that `ServiceLifecycle` can start and shutdown `ComponentLifecycle`s.

In fact, since `ComponentLifecycle` conforms to `LifecycleTask`,
it can start and stop other `ComponentLifecycle`s, forming a tree. E.g.:

```swift
struct SubSystem {
    let lifecycle = ComponentLifecycle(label: "SubSystem")
    let subsystem: SubSubSystem

    init() {
        self.subsystem = SubSubSystem()
        self.lifecycle.register(self.subsystem.lifecycle)
    }

    struct SubSubSystem {
        let lifecycle = ComponentLifecycle(label: "SubSubSystem")

        init() {
            self.lifecycle.register(...)
        }
    }
}

let lifecycle = ServiceLifecycle()
let subsystem = SubSystem()
lifecycle.register(subsystem.lifecycle)

lifecycle.start { error in
    ...
}
lifecycle.wait()
```

### Compatibility with SwiftNIO Futures

[SwiftNIO](https://github.com/apple/swift-nio) is a popular networking library that among other things provides Future abstraction named `EventLoopFuture`.

Swift Service Lifecycle comes with a compatibility module designed to make managing SwiftNIO based resources easy.

Once you import `LifecycleNIOCompat` module, `LifecycleHandler` gains a static helper named `eventLoopFuture` designed to help simplify the registration call to:

```swift
let foo = ...
lifecycle.register(
    label: "foo",
    start: .eventLoopFuture(foo.start),
    shutdown: .eventLoopFuture(foo.shutdown)
)
```

or, just shutdown:

```swift
let foo = ...
lifecycle.registerShutdown(
    label: "foo",
    .eventLoopFuture(foo.shutdown)
)
```

-------

Do not hesitate to get in touch as well, over on https://forums.swift.org/c/server.

## Security

Please see [SECURITY.md](SECURITY.md) for details on the security process.
