// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EnsoLab",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "EnsoLab",
            path: "Sources/EnsoLab",
            // Design lab, not shipping code: stay on Swift 5 language mode so
            // Swift 6 strict-concurrency doesn't churn the AppKit shims.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
