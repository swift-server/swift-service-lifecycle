// swift-tools-version:5.0

import PackageDescription

let package = Package(
    name: "swift-service-lifecycle",
    products: [
        .library(name: "Lifecycle", targets: ["Lifecycle"]),
        .library(name: "LifecycleNIOCompat", targets: ["LifecycleNIOCompat"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", "1.0.0" ..< "3.0.0"),
        .package(url: "https://github.com/swift-server/swift-backtrace.git", from: "1.1.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"), // used in tests
    ],
    targets: []
)

#if compiler(>=5.3)
package.dependencies += [
    .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.0"),
]
package.targets += [
    .target(name: "Lifecycle", dependencies: ["Logging", "Metrics", "Backtrace", "Atomics"]),
]
#else
package.targets += [
    .target(name: "CLifecycleHelpers", dependencies: []),
    .target(name: "Lifecycle", dependencies: ["CLifecycleHelpers", "Logging", "Metrics", "Backtrace"]),
]
#endif

package.targets += [
    .target(name: "LifecycleNIOCompat", dependencies: ["Lifecycle", "NIO"]),
    .testTarget(name: "LifecycleTests", dependencies: ["Lifecycle", "LifecycleNIOCompat"]),
]
