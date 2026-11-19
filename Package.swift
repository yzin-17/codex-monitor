// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexNotch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexNotch", targets: ["CodexNotch"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.5.0")
    ],
    targets: [
        .executableTarget(
            name: "CodexNotch",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            path: "Sources/CodexNotch",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "CodexNotchTests",
            dependencies: ["CodexNotch"],
            path: "Tests/CodexNotchTests"
        )
    ]
)
