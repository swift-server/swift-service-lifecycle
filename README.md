# Swift Service Lifecycle

Swift Service Lifecycle provides a basic mechanism to cleanly start up and shut down an application, freeing resources in-order before exiting.
It also provides a `Signal`-based shutdown hook, to shut down on signals like `TERM` or `INT`.

Swift Service Lifecycle was designed with the idea that every application has some startup and shutdown workflow-like-logic which is often sensitive to failure and hard to get right.
The library encodes this common need in a safe and reusable way that is non-framework specific, and designed to be integrated with any server framework or directly in an application. Furthermore, it integrates natively with Structured Concurrency.

This is the beginning of a community-driven open-source project actively seeking [contributions](CONTRIBUTING.md), be it code, documentation, or ideas. What Swift Service Lifecycle provides today is covered in the [API docs](https://swiftpackageindex.com/swift-server/swift-service-lifecycle/main/documentation/servicelifecycle), but it will continue to evolve with community input.

## Getting started

Swift Service Lifecycle should be used if you have a server-side Swift application or a cross-platform (e.g. Linux, macOS) application, and you would like to manage its startup and shutdown lifecycle. Below you will find all you need to know to get started.

### Adding the dependency

To add a dependency on the package, declare it in your `Package.swift`:

```swift
.package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
```

and add `ServiceLifecycle` to the dependencies of your application target:

```swift
.product(name: "ServiceLifecycle", package: "swift-service-lifecycle")
```

Example `Package.swift` file with `ServiceLifecycle` as a dependency:

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

###  Using ServiceLifecycle

You can find a short usage example below. You can find more detailed
documentation on how to use ServiceLifecycle
[here](https://swiftpackageindex.com/swift-server/swift-service-lifecycle/main/documentation/servicelifecycle).

ServiceLifecycle consists of two main building blocks. The `Service` protocol and the `ServiceGroup`
actor. As a library or application developer you should model your long-running work as services
that implement the `Service` protocol. The protocol only requires the implementation of a single
`func run() async throws` method. Once implemented, your application you can use the `ServiceGroup`
to orchestrate multiple services. The group will spawn a child task for each service and call the
respective `run` method in the child task. Furthermore, the group will setup signal listeners for
the configured signals and trigger a graceful shutdown on each service.

```swift
import ServiceLifecycle
import Logging

// A service can be implemented by a struct, class or actor. For this example we are using a struct.
struct FooService: Service {
    func run() async throws {
        print("FooService starting")
        try await Task.sleep(for: .seconds(10))
        print("FooService done")
    }
}

@main
struct Application {
    static let logger = Logger(label: "Application")
    
    static func main() async throws {
        let service1 = FooService()
        let service2 = FooService()
        
        let serviceGroup = ServiceGroup(
            services: [service1, service2],
            gracefulShutdownSignals: [.sigterm],
            logger: logger
        )
        
        try await serviceGroup.run()
    }
}
```

## Security

Please see [SECURITY.md](SECURITY.md) for details on the security process.
