# ``ServiceLifecycle``

A library for cleanly starting up and shutting down applications.

## Overview

Applications often have to orchestrate multiple internal services such as
clients or servers to implement their business logic. Doing this can become
tedious; especially when the APIs of the various services are not interoping nicely
with each other. This library tries to solve this issue by providing a ``Service`` protocol
that services should implement and an orchestrator, the ``ServiceGroup``, that handles
running the various services.

This library is fully based on Swift Structured Concurrency which allows it to
safely orchestrate the individual services in separate child tasks. Furthermore, this library
complements the cooperative task cancellation from Structured Concurrency with a new mechanism called
_graceful shutdown_. Cancellation is indicating the tasks to stop their work as soon as possible
whereas _graceful shutdown_ just indicates them that they should come to an end but it is up
to their business logic if and how to do that.

``ServiceLifecycle`` should be used by both library and application authors to create a seamless experience.
Library authors should conform their services to the ``Service`` protocol and application authors
should use the ``ServiceGroup`` to orchestrate all their services.

## Getting started

If you have a server-side Swift application or a cross-platform (e.g. Linux, macOS) application, and you would like to manage its startup and shutdown lifecycle, Swift Service Lifecycle is a great idea. Below you will find all you need to know to get started.

### Adding the dependency

To add a dependency on the package, declare it in your `Package.swift`:

```swift
.package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.3.0"),
```

and to your application target, add `ServiceLifecycle` to your dependencies:

```swift
.product(name: "ServiceLifecycle", package: "swift-service-lifecycle")
```

Example `Package.swift` file with `ServiceLifecycle` as a dependency:

```swift
// swift-tools-version:5.9
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

- <doc:How-to-adopt-ServiceLifecycle-in-libraries>
- <doc:How-to-adopt-ServiceLifecycle-in-applications>

### Service protocol

- ``Service``

### Service Group

- ``ServiceGroup``
- ``ServiceGroupConfiguration``

### Graceful Shutdown

- ``withGracefulShutdownHandler(operation:onGracefulShutdown:)``
- ``cancelOnGracefulShutdown(_:)``

### Errors

- ``ServiceGroupError``
