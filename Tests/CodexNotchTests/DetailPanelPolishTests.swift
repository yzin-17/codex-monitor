import Foundation
import Testing
@testable import CodexNotch

@MainActor
@Test func codexRadarDefaultsOnButPreservesExplicitOptOut() throws {
    let freshSuite = "radar-default-on-\(UUID())"
    let freshDefaults = try #require(UserDefaults(suiteName: freshSuite))
    defer { freshDefaults.removePersistentDomain(forName: freshSuite) }

    let freshSettings = CodexNotchSettings(
        defaults: freshDefaults,
        initialManagementKey: "",
        initialNewAPIKey: "",
        initialSubAPIKey: "",
        secretStores: SecretStoreFactory(
            keychain: MemorySecretStore(),
            database: MemorySecretStore()
        ),
        launchAtLoginManager: DetailPanelLaunchAtLoginManager(),
        loadSecretsSynchronously: true
    )
    _ = CodexRadarViewModel(
        settings: freshSettings,
        selectionDefaults: freshDefaults,
        previewSnapshot: .disabled
    )
    #expect(freshSettings.codexRadarEnabled)
    #expect(freshDefaults.object(forKey: "codexRadarEnabled") as? Bool == true)

    let optedOutSuite = "radar-explicit-off-\(UUID())"
    let optedOutDefaults = try #require(UserDefaults(suiteName: optedOutSuite))
    defer { optedOutDefaults.removePersistentDomain(forName: optedOutSuite) }
    optedOutDefaults.set(false, forKey: "codexRadarEnabled")

    let optedOutSettings = CodexNotchSettings(
        defaults: optedOutDefaults,
        initialManagementKey: "",
        initialNewAPIKey: "",
        initialSubAPIKey: "",
        secretStores: SecretStoreFactory(
            keychain: MemorySecretStore(),
            database: MemorySecretStore()
        ),
        launchAtLoginManager: DetailPanelLaunchAtLoginManager(),
        loadSecretsSynchronously: true
    )
    _ = CodexRadarViewModel(
        settings: optedOutSettings,
        selectionDefaults: optedOutDefaults,
        previewSnapshot: .disabled
    )
    #expect(!optedOutSettings.codexRadarEnabled)
}

@Test func codexTaskFilterCanRecognizeSanitizedUnnamedTasks() {
    let named = CodexTask(
        id: "named",
        title: "正常任务",
        status: .recent,
        detailPrefix: "gpt-5.6-sol",
        tokenCount: 1,
        updatedAt: Date()
    )
    let unnamed = CodexTask(
        id: "unnamed",
        title: "The following is the Codex agent history. >>> TRANSCRIPT START",
        status: .recent,
        detailPrefix: "gpt-5.6-sol",
        tokenCount: 1,
        updatedAt: Date()
    )

    #expect(named.title != TaskTitleSanitizer.fallback)
    #expect(unnamed.title == TaskTitleSanitizer.fallback)
}

private struct DetailPanelLaunchAtLoginManager: LaunchAtLoginManaging {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws {}
}
