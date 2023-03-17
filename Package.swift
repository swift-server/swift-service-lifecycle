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
    ],
    targets: [
        .target(
            name: "ServiceLifecycle",
            dependencies: [
                .product(
                    name: "Logging",
                    package: "swift-log"
                ),
                .target(name: "UnixSignals"),
            ]
        ),
        .target(
            name: "ServiceLifecycleTestKit",
            dependencies: [
                .target(name: "ServiceLifecycle"),
            ],
        ),
        .target(
            name: "UnixSignals"
        ),
        .testTarget(
            name: "ServiceLifecycleTests",
            dependencies: [
                .target(name: "ServiceLifecycle"),
                .target(name: "ServiceLifecycleTestKit"),
            ],
        ),
        .testTarget(
            name: "UnixSignalsTests",
            dependencies: [
                .target(name: "UnixSignals"),
            ]
        ),
    ]
)
