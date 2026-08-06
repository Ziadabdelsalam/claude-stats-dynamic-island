// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeStats",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ClaudeStatsCore", targets: ["ClaudeStatsCore"]),
        .executable(name: "ClaudeStatsApp", targets: ["ClaudeStatsApp"]),
        .executable(name: "ClaudeStatsCLI", targets: ["ClaudeStatsCLI"]),
    ],
    targets: [
        .target(
            name: "ClaudeStatsCore"
        ),
        .executableTarget(
            name: "ClaudeStatsApp",
            dependencies: ["ClaudeStatsCore"]
        ),
        .executableTarget(
            name: "ClaudeStatsCLI",
            dependencies: ["ClaudeStatsCore"]
        ),
        .testTarget(
            name: "ClaudeStatsCoreTests",
            dependencies: ["ClaudeStatsCore"],
            // Tests/ClaudeStatsCoreTests/Fixtures/ is copied verbatim into the test bundle.
            // Load fixtures with, e.g.:
            //   Bundle.module.url(forResource: "sample", withExtension: "jsonl", subdirectory: "Fixtures")
            // The directory must exist on disk or the build fails; keep at least one file in it.
            resources: [.copy("Fixtures")]
        ),
    ]
)
