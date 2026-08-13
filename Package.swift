// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaVault",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MediaVault",
            path: "Sources/MediaVault",
            resources: [.process("Resources")],
            plugins: [.plugin(name: "GenerateFinishedKeywords")]
        ),
        .executableTarget(
            name: "KeywordsGeneratorTool",
            path: "Sources/KeywordsGeneratorTool"
        ),
        .plugin(
            name: "GenerateFinishedKeywords",
            capability: .buildTool(),
            dependencies: ["KeywordsGeneratorTool"]
        ),
    ]
)
