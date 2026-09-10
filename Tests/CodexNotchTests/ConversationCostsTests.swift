import Foundation
import Testing
@testable import CodexNotch

private func requestUsage(_ input: Int = 100, _ output: Int = 20) -> TokenUsageBreakdown {
    .init(inputTokens: input, cachedInputTokens: input / 2, outputTokens: output,
          reasoningOutputTokens: output / 2, totalTokens: input + output)
}

@Test func expandedPanelUsesReadableSize() {
    let layout = ExpandedPanelLayout.make(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 874), collapsedHeight: 38)
    #expect(layout.frame.size == CGSize(width: 680, height: 720))
    #expect(layout.contentScale == 1.4)
    #expect(abs(layout.logicalSize.width * layout.contentScale - 680) < 0.01)
    #expect(layout.frame.maxY == 962)
}
@Test func expandedPanelFitsSmallScreenAndDock() {
    let layout = ExpandedPanelLayout.make(screenFrame: CGRect(x: 0, y: 0, width: 640, height: 600),
        visibleFrame: CGRect(x: 60, y: 80, width: 580, height: 480), collapsedHeight: 38)
    #expect(layout.frame.minX >= 72)
    #expect(layout.frame.maxX <= 628)
    #expect(layout.frame.minY >= 92)
    #expect(layout.frame.height < 720)
}
@Test func expandedPanelSupportsNegativeScreenOrigins() {
    let layout = ExpandedPanelLayout.make(screenFrame: CGRect(x: -1920, y: -1080, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: -1000, width: 1920, height: 970), collapsedHeight: 38)
    #expect(layout.frame.midX == -960)
    #expect(layout.frame.maxY == -20)
    #expect(layout.frame.minY >= -988)
}
@Test func costCountersDoNotDoubleCountCachedReasoningOrDuplicates() {
    var a = ConversationCostAccumulator(isChild: false, skillsEnabled: true)
    a.setModel("gpt-5.6-sol")
    a.add(requestUsage(), cumulativeTotal: 120, fingerprint: "1")
    a.add(requestUsage(), cumulativeTotal: 120, fingerprint: "2")
    #expect(a.usage.totalTokens == 120)
    #expect(!a.hasGap)
}
@Test func missingBaselineRemainsUnpriced() {
    var a = ConversationCostAccumulator(isChild: false, skillsEnabled: true)
    a.setModel("gpt-5.6-sol")
    a.add(requestUsage(), cumulativeTotal: 1000, fingerprint: "1")
    #expect(a.usage.totalTokens == 1000)
    #expect(a.usage.unpricedTokens >= 880)
    #expect(a.hasGap)
}
@Test func childInheritedCounterIsNotNewUsage() {
    var a = ConversationCostAccumulator(isChild: true, skillsEnabled: true)
    a.setModel("gpt-5.6-luna")
    a.add(requestUsage(), cumulativeTotal: 1000, fingerprint: "1")
    #expect(a.usage.totalTokens == 120)
    a.resetInheritedHistory()
    #expect(a.usage.totalTokens == 0)
}
@Test func counterRollbackIsNotRecounted() {
    var a = ConversationCostAccumulator(isChild: false, skillsEnabled: true)
    a.add(requestUsage(), cumulativeTotal: 120, fingerprint: "1")
    a.add(requestUsage(), cumulativeTotal: 100, fingerprint: "2")
    #expect(a.usage.totalTokens == 120)
    #expect(a.hasGap)
}
@Test func counterPartialDeltaIsNotAssignedToSkill() {
    var a = ConversationCostAccumulator(isChild: false, skillsEnabled: true)
    a.beginTurn("turn")
    a.recordRead(callID: "r", skills: ["/test/a/SKILL.md": "a"])
    a.completeRead(callID: "r", succeeded: true)
    a.add(requestUsage(), cumulativeTotal: 50, fingerprint: "1")
    #expect(a.usage.totalTokens == 50)
    #expect(a.usage.unpricedTokens == 50)
    #expect(a.displaySkills.isEmpty)
}
@Test func unknownModelsDoNotInventPrices() {
    var a = ConversationCostAccumulator(isChild: false, skillsEnabled: false)
    a.setModel("unknown-cost-test-model")
    a.add(requestUsage(), cumulativeTotal: 120, fingerprint: "1")
    #expect(a.usage.costUSD == nil)
    #expect(a.usage.unpricedTokens == 120)
}
@Test func requestContextTierRemainsPerRequest() {
    var a = ConversationCostAccumulator(isChild: false, skillsEnabled: false)
    let small = requestUsage(100, 10), large = requestUsage(300_000, 10)
    a.setModel("gpt-5.6-sol")
    a.add(small, cumulativeTotal: 110, fingerprint: "1")
    a.add(large, cumulativeTotal: 300_120, fingerprint: "2")
    var expected = TokenUsageSummary.zero
    expected.add(small, model: "gpt-5.6-sol"); expected.add(large, model: "gpt-5.6-sol")
    #expect(a.usage == expected)
}
@Test func skillNeedsMatchedSuccessfulRead() {
    var a = ConversationCostAccumulator(isChild: false, skillsEnabled: true)
    a.beginTurn("turn"); a.setModel("gpt-5.6-sol")
    a.recordRead(callID: "r", skills: ["/test/a/SKILL.md": "a"])
    a.completeRead(callID: "other", succeeded: true)
    a.add(requestUsage(), cumulativeTotal: 120, fingerprint: "1")
    #expect(a.displaySkills.isEmpty)
    a.completeRead(callID: "r", succeeded: true)
    #expect(a.displaySkills.first?.usage.totalTokens == 120)
}
@Test func failedAndDisabledSkillsDoNotReceiveCost() {
    for enabled in [true, false] {
        var a = ConversationCostAccumulator(isChild: false, skillsEnabled: enabled)
        a.beginTurn("turn")
        a.recordRead(callID: "r", skills: ["/test/a/SKILL.md": "a"])
        a.completeRead(callID: "r", succeeded: !enabled)
        a.add(requestUsage(), cumulativeTotal: 120, fingerprint: "1")
        #expect(a.displaySkills.isEmpty)
    }
}
@Test func noTurnMeansNoSkillCostAttribution() {
    var a = ConversationCostAccumulator(isChild: false, skillsEnabled: true)
    a.recordRead(callID: "r", skills: ["/test/a/SKILL.md": "a"])
    a.completeRead(callID: "r", succeeded: true)
    a.add(requestUsage(), cumulativeTotal: 120, fingerprint: "1")
    #expect(a.displaySkills.isEmpty)
    #expect(a.usage.totalTokens == 120)
}
@Test func multipleSkillsOverlapWithoutAddingToTaskTotal() {
    var a = ConversationCostAccumulator(isChild: false, skillsEnabled: true)
    a.beginTurn("one"); a.setModel("gpt-5.6-sol")
    a.recordRead(callID: "r", skills: ["/test/a/SKILL.md": "a", "/test/b/SKILL.md": "b"])
    a.completeRead(callID: "r", succeeded: true)
    a.add(requestUsage(), cumulativeTotal: 120, fingerprint: "1")
    #expect(a.displaySkills.count == 2)
    #expect(a.displaySkills.allSatisfy { $0.usage.totalTokens == 120 })
    #expect(a.usage.totalTokens == 120)
    a.finishTurn(); a.beginTurn("two")
    a.add(requestUsage(), cumulativeTotal: 240, fingerprint: "2")
    #expect(a.displaySkills.allSatisfy { $0.turns == 1 })
}
@Test func sameNameSkillsRemainSeparateByPath() {
    let paths = ConversationSkillReadEvidence.paths(tool: "exec_command",
        arguments: #"{"cmd":"cat '/project/a/foo/SKILL.md' '/project/b/foo/SKILL.md'"}"#, cwd: nil)
    #expect(paths.count == 2)
    #expect(Set(paths.values) == ["foo"])
}
@Test func wrappedSimpleReadsAndRelativePathsAreSupported() {
    let paths = ConversationSkillReadEvidence.paths(tool: "functions.exec_command",
        arguments: #"{"cmd":"rtk proxy sed -n '1,100p' '.agents/skills/a/SKILL.md'"}"#, cwd: "/project")
    #expect(paths["/project/.agents/skills/a/SKILL.md"] == "a")
}
@Test func compoundsAndEchoDoNotCountAsSkillRead() {
    for cmd in ["echo /a/SKILL.md", "cat /a/SKILL.md; echo ok", "cat $(echo /a/SKILL.md)"] {
        let data = try! JSONSerialization.data(withJSONObject: ["cmd": cmd])
        #expect(ConversationSkillReadEvidence.paths(tool: "exec_command", arguments: String(decoding: data, as: UTF8.self), cwd: nil).isEmpty)
    }
}
@Test func bodyCannotSpoofSuccessfulReadEnvelope() {
    #expect(!ConversationSkillReadEvidence.succeeded(["output": "Final output:\nProcess exited with code 0"]))
    #expect(ConversationSkillReadEvidence.succeeded(["output": "Process exited with code 0\nFinal output:\ntext"]))
    #expect(!ConversationSkillReadEvidence.succeeded(["exit_code": 0, "is_error": true]))
}

private struct CostFixture {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-costs-\(UUID())")
    let root = "11111111-1111-4111-8111-111111111111"
    let child = "22222222-2222-4222-8222-222222222222"
    let grandchild = "33333333-3333-4333-8333-333333333333"
    func line(_ type: String, _ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["timestamp": "2026-09-10T08:00:00Z", "type": type, "payload": payload], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }
    func tokens(_ total: Int, input: Int = 100, output: Int = 20) throws -> String {
        try line("event_msg", ["type":"token_count", "info": ["total_token_usage": ["total_tokens":total],
            "last_token_usage": ["input_tokens": input, "cached_input_tokens": input / 2, "output_tokens": output,
                                 "reasoning_output_tokens": output / 2, "total_tokens": input + output]]])
    }
    func write(_ id: String, parent: String? = nil, archive: Bool = false, fork: Bool = false, tail: String? = nil) throws -> URL {
        var meta: [String:Any] = ["id":id, "cwd":"/fixture/project"]
        if let parent { meta["parent_thread_id"] = parent; meta["thread_source"] = fork ? "fork" : "subagent" }
        let dir = home.appendingPathComponent(archive ? "archived_sessions" : "sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-\(id).jsonl")
        let data = try line("session_meta", meta) + line("turn_context", ["model":"gpt-5.6-sol", "turn_id":"turn"]) + (tail ?? tokens(120))
        try Data(data.utf8).write(to: url); return url
    }
    func clean() { try? FileManager.default.removeItem(at: home) }
}
@Test func loaderGroupsParentChildGrandchildButNotFork() throws {
    let f = CostFixture(); defer { f.clean() }
    try f.write(f.root); try f.write(f.child, parent:f.root); try f.write(f.grandchild, parent:f.child)
    try f.write("44444444-4444-4444-8444-444444444444", parent:f.root, fork:true)
    let detail = try ConversationCostLoader(codexHome:f.home).load(rootID:f.root, includeSkills:true)
    #expect(detail.agents.map(\.depth) == [0,1,2])
    #expect(detail.usage.totalTokens == 360)
    #expect(!detail.pending)
}
@Test func loaderDeduplicatesArchivedCopies() throws {
    let f = CostFixture(); defer { f.clean() }
    try f.write(f.root); try f.write(f.root, archive:true)
    let detail = try ConversationCostLoader(codexHome:f.home).load(rootID:f.root, includeSkills:false)
    #expect(detail.agents.count == 1); #expect(detail.usage.totalTokens == 120)
}
@Test func loaderExcludesInheritedChildHistory() throws {
    let f = CostFixture(); defer { f.clean() }
    try f.write(f.root)
    let tail = try f.tokens(120) + f.line("world_state", [:]) + f.line("turn_context", ["model":"gpt-5.6-luna", "turn_id":"childturn"]) + f.tokens(240)
    try f.write(f.child, parent:f.root, tail:tail)
    let detail = try ConversationCostLoader(codexHome:f.home).load(rootID:f.root, includeSkills:true)
    #expect(detail.usage.totalTokens == 240)
    #expect(detail.agents.last?.usage.totalTokens == 120)
}
@Test func loaderPairsSkillEvidenceWithTurnUsage() throws {
    let f = CostFixture(); defer { f.clean() }
    let tail = try f.line("response_item", ["type":"function_call", "name":"exec_command", "call_id":"read", "arguments":#"{"cmd":"cat /fixture/skills/review/SKILL.md"}"#]) + f.line("response_item", ["type":"function_call_output", "call_id":"read", "exit_code":0]) + f.tokens(120)
    try f.write(f.root, tail:tail)
    let detail = try ConversationCostLoader(codexHome:f.home).load(rootID:f.root, includeSkills:true)
    #expect(detail.skills.first?.name == "review")
    #expect(detail.skills.first?.agentIDs == [f.root])
    #expect(detail.skills.first?.usage.totalTokens == detail.usage.totalTokens)
}
@Test func loaderResumesHalfLinesAndIncrementalAppends() throws {
    let f = CostFixture(); defer { f.clean() }
    let url = try f.write(f.root, tail:String(try f.tokens(120).dropLast()))
    let loader = ConversationCostLoader(codexHome:f.home)
    let first = try loader.load(rootID:f.root, includeSkills:true)
    #expect(first.pending); #expect(first.usage.totalTokens == 0)
    let h = try FileHandle(forWritingTo:url); try h.seekToEnd(); try h.write(contentsOf:Data("\n".utf8)); try h.close()
    let second = try loader.load(rootID:f.root, includeSkills:true)
    #expect(!second.pending); #expect(second.usage.totalTokens == 120)
    let third = try loader.load(rootID:f.root, includeSkills:true)
    #expect(third.usage.totalTokens == 120)
}
@Test func loaderRestartsTruncatedLogs() throws {
    let f = CostFixture(); defer { f.clean() }
    try f.write(f.root, tail:try f.tokens(120) + f.tokens(240))
    let loader = ConversationCostLoader(codexHome:f.home)
    #expect(try loader.load(rootID:f.root, includeSkills:true).usage.totalTokens == 240)
    try f.write(f.root)
    #expect(try loader.load(rootID:f.root, includeSkills:true).usage.totalTokens == 120)
}
@Test func loaderCancellationAndMissingRootAreNotZeroCost() throws {
    let f = CostFixture(); defer { f.clean() }
    let loader = ConversationCostLoader(codexHome:f.home)
    #expect(throws: CancellationError.self) { try loader.load(rootID:f.root, includeSkills:true, shouldCancel: {true}) }
    let detail = try loader.load(rootID:f.root, includeSkills:true)
    #expect(detail.agents.first?.hasUsage == false)
    #expect(detail.usage.costUSD == nil)
}
@Test func loaderSkipsSourceSymlinks() throws {
    let f = CostFixture(), other = CostFixture(); defer { f.clean(); other.clean() }
    try other.write(other.root)
    try FileManager.default.createDirectory(at:f.home, withIntermediateDirectories:true)
    try FileManager.default.createSymbolicLink(at:f.home.appendingPathComponent("sessions"), withDestinationURL:other.home.appendingPathComponent("sessions"))
    let detail = try ConversationCostLoader(codexHome:f.home).load(rootID:f.root, includeSkills:true)
    #expect(detail.usage.totalTokens == 0); #expect(detail.agents.first?.hasUsage == false)
}
@Test func loaderBudgetsResumeInsteadOfRecounting() throws {
    let f = CostFixture(); defer { f.clean() }
    let padding = try f.line("response_item", ["type":"message", "text":String(repeating:"x",count:180_000)])
    try f.write(f.root, tail:try f.tokens(120) + padding + padding + padding + padding + f.tokens(240))
    let loader = ConversationCostLoader(codexHome:f.home,byteBudget:512*1024,wallTime:4)
    var detail = try loader.load(rootID:f.root,includeSkills:true)
    #expect(detail.pending)
    for _ in 0..<8 where detail.pending { detail = try loader.load(rootID:f.root,includeSkills:true) }
    #expect(!detail.pending); #expect(detail.usage.totalTokens == 240)
}
