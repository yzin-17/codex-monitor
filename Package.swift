// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "CodexMonitorCore", targets: ["CodexMonitorCore"]),
    .executable(name: "codex-monitor", targets: ["CodexMonitorCLI"])
]
var targets: [Target] = [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
    .target(name: "CodexMonitorCore", dependencies: ["CSQLite"]),
    .executableTarget(name: "CodexMonitorCLI", dependencies: ["CodexMonitorCore"]),
    .testTarget(name: "CodexMonitorCoreTests", dependencies: ["CodexMonitorCore", "CSQLite"])
]
#if os(macOS)
products.append(.executable(name: "CodexMonitor", targets: ["CodexMonitorApp"]))
targets.append(.executableTarget(name: "CodexMonitorApp", dependencies: ["CodexMonitorCore"]))
#endif
let package = Package(name: "CodexMonitor", platforms: [.macOS(.v14)], products: products, targets: targets)
