# SwiftServiceLauncher

SwiftServiceLauncher provides a basic mechanism to cleanly start up and shut down the application, freeing resources in order before exiting.
It also provides a Signal based shutdown hook, to shutdown on signals like `TERM` or `INT`.

SwiftServiceLauncher was designed with the idea that every application has some startup and shutdown workflow-like-logic which is often sensitive to failure and hard to get right.
The library codes this common need in a safe and reusable way that is non-framework specific, and designed to be integrated with any server framework or directly in an application.

This is the beginning of a community-driven open-source project actively seeking contributions, be it code, documentation, or ideas. What SwiftServiceLauncher provides today is covered in the [API docs](https://swift-server.github.io/swift-service-launcher/), but it will continue to evolve with community input.

## Getting started

If you have a server-side Swift application or a cross-platform (e.g. Linux, macOS) application, and you would like to manage its startup and shutdown lifecycle, SwiftServiceLauncher is a great idea. Below you will find all you need to know to get started.

### Adding the dependency

To add a dependency on the package, declare it in your `Package.swift`:

```swift
.package(url: "https://github.com/swift-server/swift-service-launcher.git", from: "1.0.0"),
```

and to your application target, add "SwiftServiceLauncher" to your dependencies:

```swift
.target(name: "BestExampleApp", dependencies: ["SwiftServiceLauncher"]),
```

###  Defining the lifecycle

```swift
// import the package
import ServiceLauncher

// initialize the lifecycle container
var lifecycle = Lifecycle()

// register a resource that should be shutdown when the application exists.
// in this case, we are registering a SwiftNIO EventLoopGroup
// and passing its `syncShutdownGracefully` function to be called on shutdown
let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
lifecycle.registerShutdown(
    name: "eventLoopGroup",
    eventLoopGroup.syncShutdownGracefully
)

// register another resource that should be shutdown when the application exits.
// in this case, we are registering an HTTPClient
// and passing its `syncShutdown` function to be called on shutdown
let httpClient = HTTPClient(eventLoopGroupProvider: .shared(eventLoopGroup))
lifecycle.registerShutdown(
    name: "HTTPClient",
    httpClient.syncShutdown
)

// start the application
// start handlers passed using the `register` function
// will be called in the order the items were registered in
lifecycle.start() { error in
    // this is the start completion handler.
    // if an error occurred you can log it here
    if let error = error {
        logger.error("failed starting \(self) ☠️: \(error)")
    } else {
        logger.info("\(self) started successfully 🚀")
    }
}
// wait for the application to exist
// this is a blocking operation that typically waits for
// for a signal configured at lifecycle.start (default is `INT` and `TERM`)
// or another thread calling lifecycle.shutdown (untypical)
// shutdown handlers passed using the `register` or `registerShutdown` functions
// will be called in the reverse order the items were registered in
lifecycle.wait()
```

## Detailed design

The main type in the library is `Lifecycle` which manages a state machine representing the application's startup and shutdown logic.

### Registering items

`Lifecycle` is a container for `LifecycleItem`s which need to be registered via one of the following variants:

You can register simple blocking throwing handlers using:

```swift
func register(label: String, start: @escaping () throws -> Void, shutdown: @escaping () throws -> Void)

func registerShutdown(label: String, _ handler: @escaping () throws -> Void)
```

or, you can register asynchronous and more complex handlers using:

```swift
func register(label: String, start: Handler, shutdown: Handler)

func registerShutdown(label: String, _ handler: Handler)
```

where `Lifecycle.Handler` is a container for an asynchronous closure defined as  `(@escaping (Error?) -> Void) -> Void`

`Lifecycle.Handler` comes with static helpers named `async` and `sync` designed to help simplify the registration call to:

```swift
let foo = ...
lifecycle.register(
    name: "foo",
    start: .async(foo.asyncStart),
    shutdown: .async(foo.asyncShutdown)
)
```

or, just shutdown:

```swift
let foo = ...
lifecycle.registerShutdown(
    name: "foo",
    .async(foo.asyncShutdown)
)
```


you can also register a collection of `LifecycleItem`s (less typical) using:

```swift
func register(_ items: [LifecycleItem])

internal func register(_ items: LifecycleItem...)
```

### Starting the lifecycle

Use `Lifecycle::start` function to start the application. Start handlers passed using the `register` function will be called in the order the items were registered in.

`Lifecycle::start` is an asynchronous operation. If a startup error occurred, it will be logged and the startup sequence will halt on the first error, and bubble it up to the provided completion handler.

```swift
lifecycle.start() { error in
    if let error = error {
        logger.error("failed starting \(self) ☠️: \(error)")
    } else {
        logger.info("\(self) started successfully 🚀")
    }
}
```

`Lifecycle::start` takes optional `Lifecycle.Configuration` to further refine the `Lifecycle` behavior:

* `callbackQueue`: Defines the `DispatchQueue` on which startup and shutdown handlers are executed. By default, `DispatchQueue.global` is used.

* `shutdownSignal`: Defines what, if any, signals to trap for invoking shutdown. By default, `INT` and `TERM` are trapped.

* `installBacktrace`: Defines if to install a crash signal trap that prints backtraces. This is especially useful for application running on Linux since Swift does not provide backtraces on Linux out of the box. This functionality is provided via the [Swift Backtrace](https://github.com/swift-server/swift-backtrace) library.

### Shutdown

Typical use of the library is to call on `Lifecycle::wait` after calling `Lifecycle::start`.

```swift
lifecycle.start() { error in
  ...   
}
lifecycle.wait() // <-- blocks the thread
```

If you are not interested in handling start completion, there is also a convenience method:

```swift
lifecycle.startAndWait() // <-- blocks the thread
```

`Lifecycle::wait` and `Lifecycle::startAndWait` are blocking operations that wait for the lifecycle library to finish its shutdown sequence.
The shutdown sequence is typically triggered by the `shutdownSignal` defined in the configuration. By default, `INT` and `TERM` are trapped.

During shutdown, the shutdown handlers passed using the `register` or `registerShutdown` functions are called in the reverse order of the registration. E.g.

```
lifecycle.register("1", ...)
lifecycle.register("2", ...)
lifecycle.register("3", ...)
```

startup order will be 1, 2, 3 and shutdown order will be 3, 2, 1.

If a shutdown error occurred, it will be logged and the shutdown sequence will *continue* to the next item, and attempt to shut it down until all registered items that have been started are shut down.

In more complex cases, when signal trapping based shutdown is not appropriate, you may pass `nil` as the `shutdownSignal` configuration, and call `Lifecycle::shutdown` manually when appropriate. This is a rarely used pressure valve. `Lifecycle::shutdown` is an asynchronous operation. Errors will be logged and bubble it up to the provided completion handler.

### Compatibility with SwiftNIO Futures

[SwiftNIO](https://github.com/apple/swift-nio) is a popular networking library that among other things provides Future abstraction named `EventLoopFuture`.

SwiftServiceLauncher comes with a compatibility module designed to make managing SwiftNIO based resources easy.

Once you import `ServiceLauncherNIOCompat` module, `Lifecycle.Handler` gains a static helpers named `eventLoopFuture` designed to help simplify the registration call to:

```swift
let foo = ...
lifecycle.register(
    name: "foo",
    start: .eventLoopFuture(foo.start),
    shutdown: .eventLoopFuture(foo.shutdown)
)
```  

-------


Do not hesitate to get in touch as well, over on https://forums.swift.org/c/server.
