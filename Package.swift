// swift-tools-version:5.0

import PackageDescription

let package = Package(
    name: "swift-service-launcher",
    products: [
        .library(name: "ServiceLauncher", targets: ["ServiceLauncher"]),
        .library(name: "ServiceLauncherNIOCompat", targets: ["ServiceLauncherNIOCompat"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", "1.0.0" ..< "3.0.0"),
        .package(url: "https://github.com/swift-server/swift-backtrace.git", from: "1.1.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"), // used in tests
    ],
    targets: [
        .target(name: "ServiceLauncher", dependencies: ["Logging", "Metrics", "Backtrace"]),
        .target(name: "ServiceLauncherNIOCompat", dependencies: ["ServiceLauncher", "NIO"]),
        .testTarget(name: "ServiceLauncherTests", dependencies: ["ServiceLauncher", "ServiceLauncherNIOCompat"]),
    ]
)
