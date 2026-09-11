import Foundation
import Testing
@testable import CodexNotch

@Test func incidentStatusBuildsCodexBarStyleGroupsAndAggregatesWorstChild() throws {
    let incident = Data(#"""
    {
      "summary": {
        "affected_components": [
          {"component_id":"chat-login","status":"degraded_performance"},
          {"component_id":"codex-api","status":"major_outage"}
        ],
        "structure": {"items":[
          {"group":{"id":"chatgpt","name":"ChatGPT","hidden":false,"components":[
            {"component_id":"chat-conv","name":"Conversations","hidden":false},
            {"component_id":"chat-login","name":"Login","hidden":false},
            {"component_id":"secret","name":"Hidden","hidden":true}
          ]}},
          {"group":{"id":"codex","name":"Codex","hidden":false,"components":[
            {"component_id":"codex-api","name":"Codex API","hidden":false}
          ]}}
        ]}
      }
    }
    """#.utf8)
    let overlay = Data(#"""
    {"page":{"updated_at":"2026-09-11T10:00:00Z"},"status":{"indicator":"major","description":"Partial outage"}}
    """#.utf8)

    let snapshot = try PublicInsightParser.parseOpenAIIncident(incident, statusData: overlay)
    let groups = snapshot.components.filter { $0.isGroup == true }
    #expect(groups.map(\.name) == ["ChatGPT", "Codex"])
    #expect(groups[0].state == "degraded_performance")
    #expect(groups[1].state == "major_outage")
    #expect(snapshot.components.first(where: { $0.id == "chat-conv" })?.state == "operational")
    #expect(snapshot.components.contains(where: { $0.id == "secret" }) == false)
    #expect(snapshot.overallIndicator == "critical")
    #expect(snapshot.summary == "Partial outage")
}

@Test func namedLayoutsAreIndependentFromEditorSourceSelection() {
    var config = HUDConfiguration()
    let first = HUDLayout(lines: [[HUDLayoutToken.applying(sourceID: "local", to: "weekly")]])
    config.updateActiveLayout(first)
    let before = config.activeLayout

    config.sourceID = "remote:gateway-A"
    #expect(config.activeLayout == before)
    #expect(HUDLayoutToken.sourceID(config.activeLayout.lines[0][0]) == "local")

    let secondID = config.addLayout(copyCurrent: false)
    var second = HUDLayout(lines: [["fiveHour"]])
    second = second.settingSource("remote:gateway-A", at: .init(row: 0, index: 0))
    config.updateActiveLayout(second)
    #expect(config.activeLayoutID == secondID)
    #expect(HUDLayoutToken.sourceID(config.activeLayout.lines[0][0]) == "remote:gateway-A")

    config.selectLayout("default")
    #expect(HUDLayoutToken.sourceID(config.activeLayout.lines[0][0]) == "local")
}

@Test func deletingNamedLayoutFallsBackToAnotherProfileWithoutChangingWidgetBindings() {
    var config = HUDConfiguration()
    let id = config.duplicateActiveLayout()
    config.renameActiveLayout("网关监控")
    config.updateActiveLayout(
        HUDLayout(lines: [["weekly"]]).settingSource("remote:A", at: .init(row: 0, index: 0))
    )
    #expect(config.activeLayoutID == id)
    #expect(config.activeProfile.name == "网关监控")
    #expect(HUDLayoutToken.sourceID(config.activeLayout.lines[0][0]) == "remote:A")

    config.deleteActiveLayout()
    #expect(config.layoutProfiles.count == 1)
    #expect(config.activeLayoutID == "default")
}
