# SwiftServiceLauncher

SwiftServiceLauncher provides a basic mechanism to cleanly start up and shut down the application, freeing resources in order before exiting.
It also provides a Signal based shutdown hook, to shutdown on signals like TERM or INT.

SwiftServiceLauncher is non-framework specific, designed to be integrated with any server framework or directly in an application.

## Usage

```swift
var lifecycle = Lifecycle()

let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
lifecycle.registerShutdown(
    name: "eventLoopGroup",
    eventLoopGroup.syncShutdownGracefully
)

let httpClient = HTTPClient(eventLoopGroupProvider: .shared(eventLoopGroup))
lifecycle.registerShutdown(
    name: "HTTPClient",
    httpClient.syncShutdown
)

lifecycle.start() { error in
    if let error = error {
        logger.error("failed starting \(self) ☠️: \(error)")
    } else {
        logger.info("\(self) started successfully 🚀")
    }
}
lifecycle.wait()
```
