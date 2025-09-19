# ``ServiceLifecycle``

A library for cleanly starting up and shutting down applications.

## Overview

Applications often have to orchestrate multiple internal services that orchestrate their business
logic, such as clients or servers. This quickly becomes tedious; especially when the APIs of
different services do not interoperate nicely with one another. This library sets out to solve the
issue by providing a ``Service`` protocol for services to implement, and an orchestrator, the
``ServiceGroup``, to handle running of various services.

This library is fully based on Swift Structured Concurrency, allowing it to safely orchestrate the
individual services in separate child tasks. Furthermore, the library complements the cooperative
task cancellation from Structured Concurrency with a new mechanism called _graceful shutdown_. While
cancellation is a signal for a task to stop its work as soon as possible, _graceful shutdown_
indicates a task that it should eventually shutdown, but it is up to the underlying business logic
to decide if and when that happens.

``ServiceLifecycle`` should be used by both library and application authors to create a seamless experience.
Library authors should conform their services to the ``Service`` protocol and application authors
should use the ``ServiceGroup`` to orchestrate all their services.

## Getting started

If you have a server-side Swift application or a cross-platform (such as Linux and macOS) application, and would like to manage its startup and shutdown lifecycle, use Swift Service Lifecycle.
Below, you will find information to get started.

### Adding the dependency

To add a dependency on the package, declare it in your `Package.swift`:

```swift
.package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.3.0"),
```

and add `ServiceLifecycle` to the dependencies of your application target:

```swift
.product(name: "ServiceLifecycle", package: "swift-service-lifecycle")
```

The following example `Package.swift` illustrates a package with `ServiceLifecycle` as a dependency:

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "my-application",
    dependencies: [
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.3.0"),
    ],
    targets: [
        .target(name: "MyApplication", dependencies: [
            .product(name: "ServiceLifecycle", package: "swift-service-lifecycle")
        ]),
        .testTarget(name: "MyApplicationTests", dependencies: [
            .target(name: "MyApplication"),
        ]),
    ]
)
```

## Topics

### Articles

- <doc:Adopting-ServiceLifecycle-in-libraries>
- <doc:Adopting-ServiceLifecycle-in-applications>

### Service protocol

- ``Service``

### Service Group

- ``ServiceGroup``
- ``ServiceGroupConfiguration``
- ``ServiceGroupError``

### Graceful Shutdown

- ``gracefulShutdown()``
- ``cancelWhenGracefulShutdown(_:)``
- ``withTaskCancellationOrGracefulShutdownHandler(isolation:operation:onCancelOrGracefulShutdown:)``
- ``withGracefulShutdownHandler(isolation:operation:onGracefulShutdown:)``
- ``AsyncCancelOnGracefulShutdownSequence``

- ``cancelOnGracefulShutdown(_:)``
- ``withGracefulShutdownHandler(operation:onGracefulShutdown:)``
- ``withGracefulShutdownHandler(operation:onGracefulShutdown:)-1x21p``
- ``withTaskCancellationOrGracefulShutdownHandler(operation:onCancelOrGracefulShutdown:)-81m01``
