// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "siri-ai",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "siri-ai", targets: ["SiriAILib"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // The importable library: engines, context, tools, server, support.
        // Other Swift packages/apps `import SiriAILib` (product: "siri-ai").
        .target(
            name: "SiriAILib",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .executableTarget(
            name: "siri_ai",
            dependencies: [
                "SiriAILib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            resources: [
                // Test fixture shipped so the AX-cleaner regression tests run on CI
                // and on machines without a live Siri session (they silently skip
                // when the fixture is absent).
                .copy("Fixtures/ax-sessions.json"),
            ],

            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        // Runnable demo of the library surface (streaming, repo grounding,
        // tool use). Build with `swift run Example …`.
        .executableTarget(
            name: "Example",
            dependencies: [
                "SiriAILib",
            ],
            path: "Examples/SwiftExample",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .testTarget(
            name: "siri_aiTests",
            dependencies: ["siri_ai", "SiriAILib"],
            resources: [
                // Recorded AX sessions replayed by AXCleanerFixtureTests; copied
                // into the test bundle so the fixture tests also run on CI and
                // on machines without a live Siri session.
                .copy("Fixtures/ax-sessions.json"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
    ]
)
