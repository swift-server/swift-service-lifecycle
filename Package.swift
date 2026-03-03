// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "swift-service-lifecycle",
    products: [
        .library(
            name: "ServiceLifecycle",
            targets: ["ServiceLifecycle"]
        ),
        .library(
            name: "ServiceLifecycleTestKit",
            targets: ["ServiceLifecycleTestKit"]
        ),
        .library(
            name: "UnixSignals",
            targets: ["UnixSignals"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-log.git",
            from: "1.5.2"
        ),
        .package(
            url: "https://github.com/apple/swift-async-algorithms.git",
            from: "1.0.4"
        ),
    ],
    targets: [
        .target(
            name: "ServiceLifecycle",
            dependencies: [
                .product(
                    name: "Logging",
                    package: "swift-log"
                ),
                .product(
                    name: "AsyncAlgorithms",
                    package: "swift-async-algorithms"
                ),
                .target(name: "UnixSignals"),
                .target(name: "ConcurrencyHelpers"),
            ]
        ),
        .target(
            name: "ServiceLifecycleTestKit",
            dependencies: [
                .target(name: "ServiceLifecycle")
            ]
        ),
        .target(
            name: "UnixSignals",
            dependencies: [
                .target(name: "ConcurrencyHelpers")
            ]
        ),
        .target(
            name: "ConcurrencyHelpers"
        ),
        .testTarget(
            name: "ServiceLifecycleTests",
            dependencies: [
                .target(name: "ServiceLifecycle"),
                .target(name: "ServiceLifecycleTestKit"),
            ]
        ),
        .testTarget(
            name: "UnixSignalsTests",
            dependencies: [
                .target(name: "UnixSignals")
            ]
        ),
    ]
)

for target in package.targets {
    #if compiler(<6.2)
    // Needed since Sendable checking with isolated methods is not working correctly before 6.2
    if target.swiftSettings == nil {
        target.swiftSettings = []
    }
    target.swiftSettings?.append(.swiftLanguageMode(.v5))
    #endif
}
