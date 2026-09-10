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
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "CodexMonitorCore", dependencies: ["CSQLite"]),
        .testTarget(name: "CodexMonitorCoreTests", dependencies: ["CodexMonitorCore", "CSQLite"]),
        .executableTarget(
            name: "CodexNotch",
            dependencies: ["CodexMonitorCore"],
            path: "Sources/CodexNotch",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "CodexNotchTests",
            dependencies: ["CodexNotch", "CodexMonitorCore"],
            path: "Tests/CodexNotchTests"
        )
    ]
)
