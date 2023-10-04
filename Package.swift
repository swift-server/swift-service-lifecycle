// swift-tools-version:5.7

import PackageDescription

let package = Package(
    name: "swift-service-lifecycle",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .watchOS(.v6),
        .tvOS(.v13),
    ],
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
            url: "https://github.com/apple/swift-docc-plugin",
            from: "1.0.0"
        ),
        .package(
            url: "https://github.com/apple/swift-collections.git",
            from: "1.0.0"
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
                .target(name: "_AsyncMergeSequence"),
                .target(name: "UnixSignals"),
                .target(name: "ConcurrencyHelpers"),
            ]
        ),
        .target(
            name: "ServiceLifecycleTestKit",
            dependencies: [
                .target(name: "ServiceLifecycle"),
            ]
        ),
        .target(
            name: "UnixSignals",
            dependencies: [
                .target(name: "ConcurrencyHelpers"),
            ]
        ),
        .target(
            name: "ConcurrencyHelpers"
        ),
        .target(
            name: "_AsyncMergeSequence",
            dependencies: [
                .product(
                    name: "DequeModule",
                    package: "swift-collections"
                ),
            ]
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
                .target(name: "UnixSignals"),
            ]
        ),
    ]
)
