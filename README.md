# Swift Service Lifecycle

Swift Service Lifecycle provides a basic mechanism to cleanly start up and shut down the application, freeing resources in order before exiting.
It also provides a `Signal`-based shutdown hook, to shut down on signals like `TERM` or `INT`.

Swift Service Lifecycle was designed with the idea that every application has some startup and shutdown workflow-like-logic which is often sensitive to failure and hard to get right.
The library codes this common need in a safe and reusable way that is non-framework specific, and designed to be integrated with any server framework or directly in an application. Furthermore, it integrates natively with Structured Concurrency.

This is the beginning of a community-driven open-source project actively seeking [contributions](CONTRIBUTING.md), be it code, documentation, or ideas. What Swift Service Lifecycle provides today is covered in the [API docs](https://swiftpackageindex.com/swift-server/swift-service-lifecycle/main/documentation/lifecycle), but it will continue to evolve with community input.

## Getting started

If you have a server-side Swift application or a cross-platform (e.g. Linux, macOS) application, and you would like to manage its startup and shutdown lifecycle, Swift Service Lifecycle is a great idea. Below you will find all you need to know to get started.

### Adding the dependency

To add a dependency on the package, declare it in your `Package.swift`:

```swift
.package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "1.0.0-alpha.2"),
```

and to your application target, add `ServiceLifecycle` to your dependencies:

```swift
.target(name: "MyApplication", dependencies: [.product(name: "ServiceLifecycle", package: "swift-service-lifecycle")]),
```

###  Using ServiceLifecycle

You can find the documentation on how to use ServiceLifecycle over [here](https://swiftpackageindex.com/swift-server/swift-service-lifecycle/main/documentation/lifecycle).

Do not hesitate to get in touch as well, over on https://forums.swift.org/c/server.

## Security

Please see [SECURITY.md](SECURITY.md) for details on the security process.
