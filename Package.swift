// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentUsage",
    platforms: [.macOS(.v14)],
    products: [
        // What the apps link: the `usage.json` shape and the formatting both of
        // them render with. Nothing in it touches a credential or a transcript.
        .library(name: "AgentUsageModel", targets: ["AgentUsageModel"]),
        .executable(name: "agent-usage", targets: ["agent-usage"]),
    ],
    targets: [
        // Swift 6 mode so it stays Sendable-clean for whichever app links it.
        .target(name: "AgentUsageModel"),
        // The launchd job. Language mode 5: a run-once CLI with no actors of
        // its own gains nothing from strict concurrency.
        .executableTarget(
            name: "agent-usage",
            dependencies: ["AgentUsageModel"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
