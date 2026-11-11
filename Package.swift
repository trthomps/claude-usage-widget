// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeUsage", targets: ["ClaudeUsage"]),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeUsage",
            path: "Sources/ClaudeUsage"
        ),
    ]
)
