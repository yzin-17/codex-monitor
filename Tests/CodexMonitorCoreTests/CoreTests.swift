import XCTest
import Foundation
import CSQLite
@testable import CodexMonitorCore

final class TokensTests: XCTestCase {
    func testCachedAndReasoningAreSubsets() {
        let t = Tokens(input: 100, cached: 60, output: 30, reasoning: 20)
        XCTAssertEqual(t.total, 130); XCTAssertEqual(t.uncached, 40)
        XCTAssertEqual(t.cacheRatio, 0.6)
    }
    func testInvalidSubsetsAreClamped() {
        XCTAssertEqual(Tokens(input: -1, cached: 100, output: 2, reasoning: 8), Tokens(input: 0, output: 2, reasoning: 2))
    }
    func testOverflowSaturates() { XCTAssertEqual((Tokens(input: Int64.max) + Tokens(input: 20)).total, Int64.max) }
    func testZeroInputRatioUnknown() { XCTAssertNil(Tokens.zero.cacheRatio) }
    func testDisplay() { XCTAssertEqual(Display.tokens(1500), "1.5K"); XCTAssertEqual(Display.tokens(1000000), "1.00M") }
}

final class ParserTests: XCTestCase {
    func testCumulativeCountersNotSummed() throws {
        var s = state()
        consume(token(100, output: 10, lastInput: 100, lastOutput: 10), &s)
        consume(token(240, output: 25, lastInput: 140, lastOutput: 15, time: 1), &s)
        XCTAssertEqual(s.session.ownTokens.total, 265)
        XCTAssertEqual(s.session.samples.count, 2)
    }
    func testDuplicateEventsNotAdded() {
        var s = state(); let t = token(100, output: 10, lastInput: 100, lastOutput: 10)
        consume(t, &s); consume(t, &s)
        XCTAssertEqual(s.session.ownTokens.total, 110)
    }
    func testCounterGapIsNotAssignedToModelOrDate() {
        var s = state()
        consume(token(100, output: 10, lastInput: 100, lastOutput: 10), &s)
        consume(token(500, output: 100, lastInput: 5, lastOutput: 1, time: 2), &s)
        XCTAssertTrue(s.session.samples.last!.isBaseline)
        XCTAssertNil(s.session.samples.last!.date)
    }
    func testSameCounterAtDifferentTimeNotAdded() {
        var s = state()
        consume(token(100, output: 10, lastInput: 100, lastOutput: 10), &s)
        consume(token(100, output: 10, lastInput: 100, lastOutput: 10, time: 2), &s)
        XCTAssertEqual(s.session.samples.count, 1)
    }
    func testRollbackNotRecounted() {
        var s = state()
        consume(token(100, output: 10, lastInput: 100, lastOutput: 10), &s)
        consume(token(90, output: 9, lastInput: 90, lastOutput: 9, time: 1), &s)
        XCTAssertEqual(s.session.ownTokens.total, 110)
        XCTAssertTrue(s.session.issues.contains { $0.contains("回退") })
    }
    func testBaselineUnattributed() {
        var s = state()
        consume(token(1000, output: 100, lastInput: 10, lastOutput: 1), &s)
        XCTAssertTrue(s.session.samples[0].isBaseline)
        XCTAssertNil(s.session.samples[0].date)
        XCTAssertEqual(LedgerMath.usage([s.session], since: .distantPast), .zero)
        XCTAssertEqual(s.session.ownTokens.total, 1100)
    }
    func testMissingTotalsNotInferred() {
        var s = state()
        consume(["type":"event_msg", "payload":["type":"token_count", "info":["last_token_usage":["input_tokens":10,"output_tokens":2]]]], &s)
        XCTAssertTrue(s.session.samples.isEmpty); XCTAssertFalse(s.session.issues.isEmpty)
    }
    func testMalformedJSONMarkedPartial() {
        var s = state(); SessionParser.consume(Data("{broken}".utf8), offset: 0, state: &s, skillsEnabled: true)
        XCTAssertFalse(s.session.issues.isEmpty)
    }
    func testUnknownEventsIgnored() {
        var s = state(); consume(["type":"something-new","payload":["input_tokens":9999]], &s)
        XCTAssertTrue(s.session.samples.isEmpty)
    }
    func testParentMetadataDecoded() {
        var s = ParserState(path: "/tmp/file")
        consume(["type":"session_meta","payload":["id":"c","source":["subagent":["thread_spawn":["parent_thread_id":"p"]]]]], &s)
        XCTAssertEqual(s.session.parentID, "p"); XCTAssertTrue(s.session.isSubagent)
    }
    func testCompaction() {
        var s = state(); consume(["type":"compacted","payload":[:]], &s); XCTAssertEqual(s.session.compactions, 1)
    }
    func testQuotaComesFromLocalLog() {
        var s = state()
        consume(["type":"event_msg","timestamp":"2026-09-10T00:00:00Z","payload":["type":"token_count","rate_limits":["primary":["used_percent":20,"window_minutes":300,"resets_at":1790000000]]]], &s)
        XCTAssertEqual(s.session.quotas.first?.remainingPercent, 80)
    }
    func testSkillsDisabledDoesNotExtractEvidence() {
        var s = state()
        let row = json(["type":"event_msg","payload":["type":"user_message","message":"请使用 $code-review"]])
        SessionParser.consume(row, offset: 0, state: &s, skillsEnabled: false)
        XCTAssertTrue(s.session.evidence.isEmpty)
    }
    func testMentionDoesNotMeanRead() {
        var s = state(); consume(["type":"event_msg","payload":["type":"user_message","message":"使用 $code-review"]], &s)
        XCTAssertEqual(s.session.evidence.first?.kind, .requested)
        XCTAssertFalse(s.session.evidence.contains { $0.kind == .fileRead })
    }
    func testReadNeedsMatchedSuccess() {
        var s = state()
        consume(call("cat '/repo/.agents/skills/code-review/SKILL.md'"), &s)
        XCTAssertEqual(s.session.evidence.map(\.kind), [.readAttempt])
        consume(["type":"response_item","payload":["type":"function_call_output","call_id":"call-1","output":"Process exited with code 0\nFinal output:\n# Skill"]], &s)
        XCTAssertEqual(s.session.evidence.map(\.kind), [.readAttempt, .fileRead])
    }
    func testFailedReadNotCountedSuccessful() {
        var s = state(); consume(call("cat /repo/review/SKILL.md"), &s)
        consume(["type":"response_item","payload":["type":"function_call_output","call_id":"call-1","output":"Process exited with code 1"]], &s)
        XCTAssertEqual(s.session.evidence.count, 1)
    }
    func testNoStatusReadStaysAttempt() {
        var s = state(); consume(call("cat /repo/review/SKILL.md"), &s)
        consume(["type":"response_item","payload":["type":"function_call_output","call_id":"call-1","output":"some content"]], &s)
        XCTAssertEqual(s.session.evidence.count, 1)
    }
    func testEchoAndCompoundShellDoNotCountAsRead() {
        XCTAssertTrue(SessionParser.readPaths("echo /x/SKILL.md", cwd: nil).isEmpty)
        XCTAssertTrue(SessionParser.readPaths("cat /x/SKILL.md && curl example.com", cwd: nil).isEmpty)
        XCTAssertTrue(SessionParser.readPaths("cat /x/SKILL.md > /tmp/out", cwd: nil).isEmpty)
    }
    func testRelativeQuotedReadPath() {
        XCTAssertEqual(SessionParser.readPaths("cat 'my skill/SKILL.md'", cwd: "/repo"), ["/repo/my skill/SKILL.md"])
    }
    func testToolResultsCannotCreateUserMention() {
        var s = state()
        consume(["type":"response_item","payload":["type":"function_call_output","call_id":"x","output":"use $code-review"]], &s)
        XCTAssertTrue(s.session.evidence.isEmpty)
    }
    private func call(_ command: String) -> [String: Any] {
        ["type":"response_item","payload":["type":"function_call","name":"exec_command","call_id":"call-1","arguments":String(data: json(["cmd":command]),encoding:.utf8)!]]
    }
}

final class ScannerTests: XCTestCase {
    func testIncrementalAppendAndHalfLine() throws {
        let f = try Fixture(); defer { f.remove() }
        let path = f.sessions.appendingPathComponent("rollout-one.jsonl")
        let first = json(token(100, output: 10, lastInput: 100, lastOutput: 10))
        var content = json(["type":"session_meta","payload":["id":"one"]]); content.append(10)
        content.append(first.prefix(first.count / 2)); try content.write(to: path)
        let scanner = IncrementalScanner(); let config = f.config
        let a = try scanner.scan(config)
        XCTAssertEqual(a.0.first?.ownTokens.total, 0); XCTAssertEqual(a.1.pendingFiles, 1)
        let handle = try FileHandle(forWritingTo: path); try handle.seekToEnd()
        try handle.write(contentsOf: first.suffix(first.count - first.count / 2)); try handle.write(contentsOf: Data([10])); try handle.close()
        let b = try scanner.scan(config)
        XCTAssertEqual(b.0.first?.ownTokens.total, 110); XCTAssertEqual(b.1.pendingFiles, 0)
        let c = try scanner.scan(config)
        XCTAssertEqual(c.0.first?.ownTokens.total, 110); XCTAssertLessThanOrEqual(c.1.bytesRead, 96)
    }
    func testTruncateRebuilds() throws {
        let f = try Fixture(); defer { f.remove() }; let path = f.sessions.appendingPathComponent("rollout-one.jsonl")
        try f.write(path, id: "one", input: 1000)
        let scanner = IncrementalScanner(); _ = try scanner.scan(f.config)
        try f.write(path, id: "one", input: 2)
        XCTAssertEqual(try scanner.scan(f.config).0.first?.ownTokens.total, 3)
    }
    func testSourceSymlinkEscapeSkipped() throws {
        let f = try Fixture(); defer { f.remove() }
        let external = f.root.appendingPathComponent("secret.jsonl"); try Data("sensitive".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: f.sessions.appendingPathComponent("rollout-link.jsonl"), withDestinationURL: external)
        XCTAssertEqual(try IncrementalScanner().scan(f.config).1.files, 0)
    }
    func testCacheCannotBeUnderCodex() throws {
        let f = try Fixture(); defer { f.remove() }; var config = f.config
        config.cacheDirectory = f.home.appendingPathComponent("cache").path
        XCTAssertThrowsError(try IncrementalScanner().scan(config))
    }
    func testCacheHasNoPromptContent() throws {
        let f = try Fixture(); defer { f.remove() }
        let path = f.sessions.appendingPathComponent("rollout-one.jsonl")
        try f.write(path, id: "one", input: 10)
        let handle = try FileHandle(forWritingTo: path); try handle.seekToEnd()
        try handle.write(contentsOf: json(["type":"event_msg","payload":["type":"user_message","message":"secret-password-never-save"]]) + Data([10])); try handle.close()
        var config = f.config; config.cacheDirectory = f.root.appendingPathComponent("cache").path
        _ = try IncrementalScanner().scan(config)
        let cache = try String(contentsOfFile: config.cacheDirectory! + "/scan-v1.json", encoding: .utf8)
        XCTAssertFalse(cache.contains("secret-password-never-save"))
        let document = try JSONSerialization.jsonObject(with: Data(cache.utf8)) as! [String:Any]
        let cursors = document["files"] as! [String:[String:Any]]
        XCTAssertNil(cursors.values.first?["anchor"])
        XCTAssertNotNil(cursors.values.first?["anchorHash"])
        let mode = try FileManager.default.attributesOfItem(atPath: config.cacheDirectory! + "/scan-v1.json")[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertEqual(try IncrementalScanner().scan(config).0.first?.ownTokens.total, 11)
    }
    func testWarmCacheIsNotRewritten() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(f.sessions.appendingPathComponent("rollout-one.jsonl"), id: "one", input: 10)
        var config = f.config; config.cacheDirectory = f.root.appendingPathComponent("cache").path
        let scanner = IncrementalScanner(); _ = try scanner.scan(config)
        let cache = Paths.url(config.cacheDirectory!).appendingPathComponent("scan-v1.json")
        let before = try FileManager.default.attributesOfItem(atPath:cache.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval:0.02)
        _ = try scanner.scan(config)
        let after = try FileManager.default.attributesOfItem(atPath:cache.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }
    func testReadOnlySourceUnchanged() throws {
        let f = try Fixture(); defer { f.remove() }; let path = f.sessions.appendingPathComponent("rollout-one.jsonl")
        try f.write(path, id: "one", input: 10); let before = try Data(contentsOf: path)
        _ = try IncrementalScanner().scan(f.config)
        XCTAssertEqual(try Data(contentsOf: path), before)
    }
    func testOversizedRowRecovers() throws {
        let f = try Fixture(); defer { f.remove() }; let path = f.sessions.appendingPathComponent("rollout-one.jsonl")
        var data = Data(repeating: 120, count: 1100 * 1024); data.append(10)
        data.append(json(["type":"session_meta","payload":["id":"one"]])); data.append(10)
        data.append(json(token(10, output: 1, lastInput: 10, lastOutput: 1))); data.append(10); try data.write(to: path)
        let result = try IncrementalScanner().scan(f.config)
        XCTAssertEqual(result.0.first?.ownTokens.total, 11); XCTAssertFalse(result.0.first!.issues.isEmpty)
    }
    func testCancellation() throws {
        let f = try Fixture(); defer { f.remove() }; try f.write(f.sessions.appendingPathComponent("rollout-one.jsonl"), id: "one", input: 1)
        XCTAssertThrowsError(try IncrementalScanner().scan(f.config, cancelled: { true }))
    }
    func testArchivedIncluded() throws {
        let f = try Fixture(); defer { f.remove() }
        let dir = f.home.appendingPathComponent("archived_sessions"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try f.write(dir.appendingPathComponent("rollout-archived.jsonl"), id: "archived", input: 3)
        XCTAssertEqual(try IncrementalScanner().scan(f.config).0.count, 1)
    }
}

final class AggregationTests: XCTestCase {
    func testNestedChildrenCountOnce() {
        let root = sampleSession("r", amount: 100)
        var child = sampleSession("c", amount: 30); child.parentID = "r"
        var grand = sampleSession("g", amount: 20); grand.parentID = "c"
        let tasks = LedgerMath.tasks([root, child, grand])
        XCTAssertEqual(tasks.count, 1); XCTAssertEqual(tasks.first?.total.total, 150)
        XCTAssertEqual(tasks.first?.childrenTokens.total, 50)
    }
    func testDescendantOfCycleUsesSameRepresentative() {
        var a = sampleSession("z", amount: 10); var b = sampleSession("y", amount: 20)
        var child = sampleSession("a", amount: 30)
        a.parentID = "y"; b.parentID = "z"; child.parentID = "y"
        let tasks = LedgerMath.tasks([a,b,child])
        XCTAssertEqual(tasks.count, 1); XCTAssertEqual(tasks[0].total.total, 60)
    }
    func testUnknownParentKeptVisible() {
        var child = sampleSession("c", amount: 30); child.parentID = "missing"
        XCTAssertEqual(LedgerMath.tasks([child]).first?.total.total, 30)
    }
    func testCyclesDoNotHangOrDuplicate() {
        var a = sampleSession("a", amount: 10); var b = sampleSession("b", amount: 20)
        a.parentID = "b"; b.parentID = "a"
        let tasks = LedgerMath.tasks([a,b]); XCTAssertEqual(tasks.count, 1); XCTAssertEqual(tasks[0].total.total, 30)
    }
    func testDuplicateFilesSameID() {
        let s = sampleSession("a", amount: 10)
        XCTAssertEqual(LedgerMath.merge([s,s]).first?.ownTokens.total, 10)
    }
    func testForkHistoryExcluded() {
        let root = sampleSession("r", amount: 10)
        var fork = sampleSession("f", amount: 20); fork.forkedFromID = "r"
        fork.samples.insert(root.samples[0], at: 0)
        let merged = LedgerMath.merge([root,fork])
        XCTAssertEqual(LedgerMath.usage(merged).total, 30)
    }
    func testTimeWindowUsesEventDateNotFileDate() {
        let t = Date(timeIntervalSince1970: 10000)
        var s = sampleSession("r", amount: 10); s.samples[0].date = t
        XCTAssertEqual(LedgerMath.usage([s], since: t.addingTimeInterval(1)).total, 0)
        XCTAssertEqual(LedgerMath.usage([s], since: t).total, 10)
    }
    func testSkillSameNameNotAssignedTwice() {
        let a = Skill(name: "review", description: "A", path: "/a/SKILL.md", scope: "用户")
        let b = Skill(name: "review", description: "B", path: "/b/SKILL.md", scope: "用户")
        var s = sampleSession("s", amount: 10)
        s.evidence = [SkillEvidence(id:"1",sessionID:"s",turnID:"1",name:"review",kind:.requested)]
        XCTAssertEqual(LedgerMath.skillRows([a,b],sessions:[s],since:nil).reduce(0){$0 + $1.evidence.count}, 0)
    }
    func testSkillReadPathMatchesEvenDifferentName() {
        let a = Skill(name: "real-name", description: "A", path: "/a/SKILL.md", scope: "用户")
        var s = sampleSession("s", amount: 10)
        s.evidence = [SkillEvidence(id:"1",sessionID:"s",turnID:"1",name:"a",path:"/a/SKILL.md",kind:.fileRead)]
        XCTAssertEqual(LedgerMath.skillRows([a],sessions:[s],since:nil)[0].count(.fileRead), 1)
    }
    func testDefaultExportRedactsSessionMetadata() throws {
        var s = sampleSession("private-id", amount: 10); s.title = "SECRET-TITLE"; s.cwd = "/secret/project"
        let snapshot = LedgerSnapshot(sessions:[s])
        for text in [Reports.markdown(snapshot), String(data: try Reports.json(snapshot),encoding:.utf8)!] {
            XCTAssertFalse(text.contains("SECRET-TITLE")); XCTAssertFalse(text.contains("/secret/project")); XCTAssertFalse(text.contains("private-id"))
        }
    }
}

final class SkillAndPriceTests: XCTestCase {
    func testMultilineFrontmatter() {
        let result = SkillCatalog.frontmatter("---\nname: code-review\ndescription: >-\n  review code\n  and tests\n---\nbody")
        XCTAssertEqual(result?.description, "review code and tests")
    }
    func testInvalidFrontmatterRejected() { XCTAssertNil(SkillCatalog.frontmatter("name: a\ndescription: b")) }
    func testQuotedDescription() {
        XCTAssertEqual(SkillCatalog.frontmatter("---\nname: 'review'\ndescription: \"a: b\"\n---")?.description, "a: b")
    }
    func testImportSkillsSnapshotStates() throws {
        let data = json(["result":["data":[["cwd":"/repo","skills":[["name":"review","description":"d","path":"/repo/review/SKILL.md","enabled":false]]]]]])
        let result = try SkillCatalog.decodeSnapshot(data)
        XCTAssertEqual(result[0].state, .disabled); XCTAssertEqual(result[0].cwd, "/repo")
    }
    func testInvalidCatalogImport() { XCTAssertThrowsError(try SkillCatalog.decodeSnapshot(Data("[]".utf8))) }
    func testUnknownPriceExcluded() {
        let sample = sampleSession("s",amount:100).samples[0]
        XCTAssertEqual(PriceBook().estimate([sample]).excludedTokens, 100)
    }
    func testPriceDoesNotDoubleCountCached() {
        let p = ModelPrice(model:"test",inputPerMillion:10,cachedPerMillion:1,outputPerMillion:20)
        var s = sampleSession("s",amount:100).samples[0]; s.model = "test"; s.tokens = Tokens(input:1000000,cached:500000,output:100000)
        XCTAssertEqual(PriceBook(models:[p]).estimate([s]).amount, 7.5)
    }
    func testLongInputOutsideRateNotGuessed() {
        let p = ModelPrice(model:"test",inputPerMillion:10,cachedPerMillion:1,outputPerMillion:20,maxInput:100)
        var s = sampleSession("s",amount:100).samples[0]; s.model = "test"; s.lastInput = 200
        XCTAssertEqual(PriceBook(models:[p]).estimate([s]).excludedTokens, 100)
    }
    func testNegativePriceRejected() {
        let data = json(["currency":"USD","note":"","models":[["model":"test","inputPerMillion":-1,"cachedPerMillion":0,"outputPerMillion":1]]])
        XCTAssertThrowsError(try PriceBook.decode(data))
    }
    func testDuplicateModelPriceRejected() {
        let p:[String:Any] = ["model":"test","inputPerMillion":1,"cachedPerMillion":0,"outputPerMillion":1]
        XCTAssertThrowsError(try PriceBook.decode(json(["currency":"USD","note":"","models":[p,p]])))
    }
}

final class IndexTests: XCTestCase {
    func testSQLiteMetadataAndParentEdges() throws {
        let f = try Fixture(); defer { f.remove() }
        let path = f.home.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,"CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT); INSERT INTO threads VALUES('child','标题','/repo'); CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT); INSERT INTO thread_spawn_edges VALUES('parent','child');",nil,nil,nil),SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf:path)
        let index = SessionIndex.load(home:f.home)
        XCTAssertEqual(index.entries["child"]?.title,"标题"); XCTAssertEqual(index.parents["child"],"parent")
        XCTAssertEqual(try Data(contentsOf:path),before)
    }
}

private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
private func consume(_ object: [String:Any], _ state: inout ParserState) {
    SessionParser.consume(json(object),offset:UInt64(state.session.samples.count * 100 + state.session.evidence.count),state:&state,skillsEnabled:true)
}
private func state() -> ParserState {
    var s = ParserState(path:"/demo/rollout-a.jsonl")
    consume(["type":"session_meta","payload":["id":"s","cwd":"/repo"]],&s)
    consume(["type":"turn_context","payload":["model":"test","turn_id":"turn1"]],&s)
    return s
}
private func token(_ input: Int, output: Int, lastInput: Int, lastOutput: Int, time: Int = 0) -> [String:Any] {
    ["type":"event_msg","timestamp":"2026-09-10T00:00:\(String(format:"%02d",time))Z","payload":["type":"token_count","info":["total_token_usage":["input_tokens":input,"output_tokens":output,"cached_input_tokens":0],"last_token_usage":["input_tokens":lastInput,"output_tokens":lastOutput,"cached_input_tokens":0],"model_context_window":272000]]]
}
private func sampleSession(_ id: String, amount: Int64) -> Session {
    Session(id:id,samples:[UsageSample(id:"\(id)-sample",date:Date(),turnID:"turn",model:"test",tokens:Tokens(input:amount))])
}
private struct Fixture {
    let root: URL
    var home: URL { root.appendingPathComponent("codex") }
    var sessions: URL { home.appendingPathComponent("sessions") }
    var config: LedgerConfiguration { LedgerConfiguration(codexHome:home.path,timeBudget:10) }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:sessions,withIntermediateDirectories:true)
    }
    func remove() { try? FileManager.default.removeItem(at:root) }
    func write(_ path: URL, id: String, input: Int) throws {
        var data = json(["type":"session_meta","payload":["id":id]]) + Data([10])
        data.append(json(token(input,output:1,lastInput:input,lastOutput:1))); data.append(10)
        try data.write(to:path)
    }
}
