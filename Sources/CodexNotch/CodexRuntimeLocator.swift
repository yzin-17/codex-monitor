import AppKit
import Foundation

enum CodexRuntimeLocator {
    private static let bundleIdentifier = "com.openai.codex"
    private static let cliBundleIdentifier = "com.openai.codex.cli"

    static func executable(
        named name: String,
        workspace: NSWorkspace = .shared,
        fileManager: FileManager = .default
    ) -> String? {
        if let bundled = firstExecutable(
            named: name,
            in: applicationCandidates(workspace: workspace, fileManager: fileManager),
            fileManager: fileManager
        ) {
            return bundled
        }
        return uniqueExecutablePaths(
            standaloneExecutableCandidates(named: name, fileManager: fileManager),
            fileManager: fileManager
        ).first
    }

    static func firstExecutable(
        named name: String,
        in applications: [URL],
        fileManager: FileManager = .default
    ) -> String? {
        for application in applications {
            if let executable = firstExecutable(
                named: name,
                in: application,
                fileManager: fileManager
            ) {
                return executable
            }
        }
        return nil
    }

    private static func firstExecutable(
        named name: String,
        in application: URL,
        fileManager: FileManager
    ) -> String? {
        let candidates = directExecutableCandidates(
            named: name,
            in: application
        )
        if let direct = uniqueExecutablePaths(candidates, fileManager: fileManager).first {
            return direct
        }

        let resources = application.appendingPathComponent("Contents/Resources", isDirectory: true)
        if name == "codex",
           let nestedBundle = nestedCLIExecutable(in: resources, fileManager: fileManager) {
            return nestedBundle
        }
        return recursiveExecutable(named: name, in: resources, fileManager: fileManager)
    }

    private static func directExecutableCandidates(
        named name: String,
        in application: URL
    ) -> [String] {
        let resources = application.appendingPathComponent("Contents/Resources", isDirectory: true)
        var candidates: [String] = []
        if name == "codex" {
            candidates.append(
                resources.appendingPathComponent(
                    "codex-cli/CodexCLI.app/Contents/MacOS/codex"
                ).standardizedFileURL.path
            )
            candidates.append(
                resources.appendingPathComponent("codex-cli/bin/codex").standardizedFileURL.path
            )
        }
        candidates.append(resources.appendingPathComponent(name).standardizedFileURL.path)
        return candidates
    }

    private static func nestedCLIExecutable(
        in resources: URL,
        fileManager: FileManager
    ) -> String? {
        guard let enumerator = fileManager.enumerator(
            at: resources,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "app" else {
                continue
            }
            defer { enumerator.skipDescendants() }
            guard let bundle = Bundle(url: url),
                  bundle.bundleIdentifier == cliBundleIdentifier,
                  let executableURL = bundle.executableURL else {
                continue
            }
            let path = executableURL.standardizedFileURL.path
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func recursiveExecutable(
        named name: String,
        in resources: URL,
        fileManager: FileManager
    ) -> String? {
        guard let enumerator = fileManager.enumerator(
            at: resources,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator where url.lastPathComponent == name {
            let path = url.standardizedFileURL.path
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func standaloneExecutableCandidates(
        named name: String,
        fileManager: FileManager
    ) -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let home = fileManager.homeDirectoryForCurrentUser
        var directories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        if let pnpmHome = environment["PNPM_HOME"], !pnpmHome.isEmpty {
            directories.append(pnpmHome)
            directories.append(URL(fileURLWithPath: pnpmHome)
                .appendingPathComponent("bin", isDirectory: true).path)
        }
        if let voltaHome = environment["VOLTA_HOME"], !voltaHome.isEmpty {
            directories.append(URL(fileURLWithPath: voltaHome)
                .appendingPathComponent("bin", isDirectory: true).path)
        }

        directories.append(contentsOf: [
            home.appendingPathComponent(".local/bin", isDirectory: true).path,
            home.appendingPathComponent(".volta/bin", isDirectory: true).path,
            home.appendingPathComponent(".codex/bin", isDirectory: true).path,
            home.appendingPathComponent("Library/pnpm", isDirectory: true).path,
            home.appendingPathComponent("Library/pnpm/bin", isDirectory: true).path,
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ])

        var seen = Set<String>()
        return directories
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name).standardizedFileURL.path }
    }

    private static func uniqueExecutablePaths(
        _ paths: [String],
        fileManager: FileManager
    ) -> [String] {
        var seen = Set<String>()
        return paths.filter { path in
            seen.insert(path).inserted && fileManager.isExecutableFile(atPath: path)
        }
    }

    private static func applicationCandidates(
        workspace: NSWorkspace,
        fileManager: FileManager
    ) -> [URL] {
        var applications: [URL] = []
        if let discovered = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            applications.append(discovered)
        }

        let homeApplications = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        applications.append(contentsOf: [
            URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true),
            homeApplications.appendingPathComponent("ChatGPT.app", isDirectory: true),
            homeApplications.appendingPathComponent("Codex.app", isDirectory: true)
        ])

        var seen = Set<String>()
        return applications.filter {
            seen.insert($0.standardizedFileURL.path).inserted
        }
    }
}
