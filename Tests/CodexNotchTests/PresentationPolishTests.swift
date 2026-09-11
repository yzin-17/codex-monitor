import Testing
@testable import CodexNotch

@Test func conversationTitleIsNotHardTruncated() {
    let title = "The following is the complete Codex review instruction"
    #expect(Formatters.shortTitle(title) == title)
    #expect(Formatters.shortTitle("   ") == "未命名任务")
}

@Test func onePercentQuotaRemainsACompleteDisplayValue() {
    let value = HUDEntityData(
        weekly: 1,
        weeklyWindow: .init(remaining: 1, label: "7d")
    ).display(.weekly, remaining: true)
    #expect(value.text == "7d 1%")
    #expect(!value.text.contains("…"))
}
