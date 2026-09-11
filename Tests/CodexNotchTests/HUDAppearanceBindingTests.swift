import Foundation
import Testing
@testable import CodexNotch

@Test func hudAppearanceDefaultsUseTenPercentTransparencyAndCustomRadius() {
    let value = HUDConfiguration()
    #expect(abs(value.hudTransparency - 0.10) < 0.0001)
    #expect(abs(value.panelTransparency - 0.10) < 0.0001)
    #expect(value.cornerRadius == 10)
    var malformed = value
    malformed.hudCornerRadius = 99
    #expect(malformed.normalized.cornerRadius == 24)
    malformed.hudCornerRadius = -4
    #expect(malformed.normalized.cornerRadius == 0)
}

@Test func insertedHUDControlsBindToSelectedSourceAndCanCoexist() {
    var layout = HUDLayout(lines: [[]])
    layout = layout.inserting(.weekly, row: 0, sourceID: "remote:gateway-a")
    layout = layout.inserting(.weekly, row: 0, sourceID: "remote:gateway-b")
    #expect(layout.lines[0].count == 2)
    #expect(HUDLayoutToken.sourceID(layout.lines[0][0]) == "remote:gateway-a")
    #expect(HUDLayoutToken.sourceID(layout.lines[0][1]) == "remote:gateway-b")
    layout = layout.inserting(.space, row: 0, sourceID: "remote:gateway-a")
    #expect(HUDLayoutToken.sourceID(layout.lines[0].last ?? "") == nil)
}

@Test func conditionalHUDControlCanBindToAnAccount() {
    let layout = HUDLayout(lines: [[]]).addingConditional(.init(), sourceID: "codex-account:00000000-0000-0000-0000-000000000001")
    #expect(HUDLayoutToken.sourceID(layout.lines[0][0]) == "codex-account:00000000-0000-0000-0000-000000000001")
}
