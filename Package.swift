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
            url: "https://github.com/apple/swift-async-algorithms",
            from: "0.1.0"
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
            ],
            // Using strict concurrency checking here to make sure we are doing everything correctly
            swiftSettings: [.unsafeFlags(["-Xfrontend", "-warn-concurrency"])]
        ),
        .target(
            name: "ServiceLifecycleTestKit",
            dependencies: [
                .target(name: "ServiceLifecycle"),
            ],
            // Using strict concurrency checking here to make sure we are doing everything correctly
            swiftSettings: [.unsafeFlags(["-Xfrontend", "-warn-concurrency"])]
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
        .testTarget(
            name: "ServiceLifecycleTests",
            dependencies: [
                .target(name: "ServiceLifecycle"),
                .target(name: "ServiceLifecycleTestKit"),
            ],
            // Using strict concurrency checking here to make sure we are doing everything correctly
            swiftSettings: [.unsafeFlags(["-Xfrontend", "-warn-concurrency"])]
        ),
        .testTarget(
            name: "UnixSignalsTests",
            dependencies: [
                .target(name: "UnixSignals"),
            ],
            // Using strict concurrency checking here to make sure we are doing everything correctly
            swiftSettings: [.unsafeFlags(["-Xfrontend", "-warn-concurrency"])]
        ),
    ]
)
