import Foundation
import Testing
@testable import CodexNotch

private func makeExecutable(_ url: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
    try fileManager.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
    )
}

@Test
func runtimeLocatorFindsMovedBundledCLIByBundleIdentifier() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("CodexRuntimeLocator-\(UUID())", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let application = root.appendingPathComponent("RenamedClient.app", isDirectory: true)
    let cliBundle = application
        .appendingPathComponent(
            "Contents/Resources/future/runtime/EmbeddedRuntime.app",
            isDirectory: true
        )
    let executable = cliBundle
        .appendingPathComponent("Contents/MacOS/runtime-codex")
    try makeExecutable(executable)

    let info: [String: Any] = [
        "CFBundleIdentifier": "com.openai.codex.cli",
        "CFBundleExecutable": "runtime-codex",
        "CFBundlePackageType": "APPL",
        "CFBundleName": "EmbeddedRuntime"
    ]
    let infoData = try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .xml,
        options: 0
    )
    try infoData.write(
        to: cliBundle.appendingPathComponent("Contents/Info.plist"),
        options: .atomic
    )

    let resolved = CodexRuntimeLocator.firstExecutable(
        named: "codex",
        in: [application],
        fileManager: fileManager
    )
    #expect(resolved == executable.standardizedFileURL.path)
}

@Test
func runtimeLocatorFindsExecutableAfterResourceLayoutMoves() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("CodexRuntimeLocator-\(UUID())", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let application = root.appendingPathComponent("FutureClient.app", isDirectory: true)
    let executable = application
        .appendingPathComponent("Contents/Resources/new/layout/deeper/codex")
    try makeExecutable(executable)

    let resolved = CodexRuntimeLocator.firstExecutable(
        named: "codex",
        in: [application],
        fileManager: fileManager
    )
    #expect(resolved == executable.standardizedFileURL.path)
}
