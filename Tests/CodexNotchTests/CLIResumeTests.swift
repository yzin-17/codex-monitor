import Foundation
import Testing
@testable import CodexNotch

private let resumeThread = "11111111-1111-4111-8111-111111111111"
private func resumeFixture(at now: Date = Date()) -> CLIResumeInspection {
    .init(context: .init(threadID: resumeThread, path: "/tmp/fixture.jsonl", cwd: "/tmp", model: "gpt-test", effort: "high",
                        sandbox: "workspace-write", approval: "on-request", fileSize: 42, modifiedAt: now),
          identity: .init(workspaceID: "workspace-fixture", subject: "user-fixture", label: "合成账号"),
          lastTurnID: "turn-fixture", quotaPaused: true, lastTurnStatus: "failed",
          usage: .init(quotas: [.init(id: "primary_window", label: "5h", usedPercent: 0, resetsAt: now.addingTimeInterval(3600), durationSeconds: 18000)]), checkedAt: now)
}
private func ticketFixture(_ check: CLIResumeInspection) -> CLIResumeTicket {
    .init(context: check.context, identity: check.identity, turnID: check.lastTurnID, observedAt: check.checkedAt.addingTimeInterval(-10),
          blockedWindows: ["primary_window"], message: "继续", sandbox: "read-only")
}
@Test func resumeRequiresExplicitQuotaErrorNotMessageText() throws {
    let root: [String:Any] = ["thread": ["id":resumeThread, "status":["type":"notLoaded"], "turns":[
        ["id":"t", "status":"failed", "error":["message":"usage_limit_exceeded", "codexErrorInfo":"Other"]]]]]
    #expect(try CLIResumePolicy.lastTurn(root, threadID: resumeThread).1 == false)
    #expect(CLIResumePolicy.isQuotaError("usage_limit_exceeded"))
    #expect(CLIResumePolicy.isQuotaError("UsageLimitExceeded"))
    #expect(!CLIResumePolicy.isQuotaError(["message":"UsageLimitExceeded"]))
}
@Test func resumeRejectsOldQuotaDifferentAccountAndNewTurn() throws {
    let check = resumeFixture(), ticket = ticketFixture(check)
    #expect(try CLIResumePolicy.canResume(ticket, with: check, now: check.checkedAt))
    var old = check; old.checkedAt = ticket.observedAt
    #expect(try !CLIResumePolicy.canResume(ticket, with: old, now: check.checkedAt))
    var other = check; other.identity.workspaceID = "other"
    #expect(throws: CLIResumeError.changedAccount) { try CLIResumePolicy.canResume(ticket, with: other, now: check.checkedAt) }
    var changed = check; changed.lastTurnID = "manually-started"
    #expect(throws: CLIResumeError.changedSession) { try CLIResumePolicy.canResume(ticket, with: changed, now: check.checkedAt) }
}
@Test func resumeMissingOrStillEmptyWindowCannotRun() throws {
    var check = resumeFixture(); let ticket = ticketFixture(check)
    check.usage.quotas[0].usedPercent = 100
    #expect(try !CLIResumePolicy.canResume(ticket, with: check, now: check.checkedAt))
    check.usage.quotas = []
    #expect(try !CLIResumePolicy.canResume(ticket, with: check, now: check.checkedAt))
}
@Test func resumeArgumentsUseExactThreadStdinAndOriginalPolicies() throws {
    let check = resumeFixture()
    let arguments = try CLIResumePolicy.arguments(context: check.context, sandbox: "read-only")
    #expect(Array(arguments.suffix(3)) == ["resume", resumeThread, "-"])
    #expect(!arguments.contains("--last") && !arguments.contains("--yolo") && !arguments.contains("--full-auto"))
    #expect(arguments.contains("approval_policy=\"on-request\""))
    #expect(arguments.contains("cli_auth_credentials_store=\"file\""))
    #expect(arguments.contains("sandbox_workspace_write.network_access=false"))
    #expect(arguments.contains("sandbox_workspace_write.writable_roots=[]"))
    #expect(!arguments.contains("继续"))
}
@Test func resumeCannotEscalateReadOnlyOrUseFullAccess() throws {
    var context = resumeFixture().context; context.sandbox = "read-only"
    #expect(throws: CLIResumeError.unsupportedSession) { try CLIResumePolicy.arguments(context: context, sandbox: "workspace-write") }
    context.model = "--yolo"
    #expect(throws: CLIResumeError.unsupportedSession) { try CLIResumePolicy.arguments(context: context, sandbox: "read-only") }
    context.model = "gpt-test"; context.effort = "unsupported-future-effort"
    #expect(throws: CLIResumeError.unsupportedSession) { try CLIResumePolicy.arguments(context: context, sandbox: "read-only") }
    context.effort = "high"
    context.sandbox = "danger-full-access"
    #expect(throws: CLIResumeError.unsupportedSession) { try CLIResumePolicy.arguments(context: context, sandbox: "danger-full-access") }
}
@Test func resumePromptDoesNotAcceptMultilineOrControlCharacters() throws {
    #expect(try CLIResumePolicy.message("  继续  ") == "继续")
    for input in ["", "继续\n删除", "a\u{1B}b", String(repeating: "字", count: 501)] {
        #expect(throws: CLIResumeError.invalidMessage) { try CLIResumePolicy.message(input) }
    }
}
@Test func handledOrCancelledResumeTicketCannotSendAgain() throws {
    let check = resumeFixture(); var ticket = ticketFixture(check)
    for phase in [CLIResumeTicket.Phase.armed, .finished, .dispatching, .attention, .cancelled] {
        ticket.phase = phase
        #expect(try !CLIResumePolicy.canResume(ticket, with: check, now: check.checkedAt))
    }
}
@Test func interruptedTurnNeverCountsAsQuotaRecoveryTarget() throws {
    let root: [String:Any] = ["thread": ["id":resumeThread, "turns":[["id":"t", "status":"interrupted", "error":["codexErrorInfo":"UsageLimitExceeded"]]]]]
    let last = try CLIResumePolicy.lastTurn(root, threadID: resumeThread)
    #expect(!last.1 && last.2 == "interrupted")
}
@Test func contextParserReadsSettingsNotUserPromptAndRejectsMissingPolicy() throws {
    let context: [String:Any] = ["type":"turn_context", "payload":["cwd":"/tmp", "model":"gpt-test", "approval_policy":"on-request", "sandbox_policy":["type":"read-only"]]]
    let head = try JSONSerialization.data(withJSONObject: ["type":"session_meta", "payload":["id":resumeThread, "model_provider":"openai"]])
    let tail = try JSONSerialization.data(withJSONObject: context)
    let value = try CLIResumeNativeFiles.parseContext(head: head, tail: tail, threadID: resumeThread, path: "/tmp/session", size: 50, modified: Date())
    #expect(value.model == "gpt-test" && value.sandbox == "read-only")
    #expect(throws: Error.self) { try CLIResumeNativeFiles.parseContext(head: head, tail: Data("{}".utf8), threadID: resumeThread, path: "/tmp/session", size: 50, modified: Date()) }
}

@Test @MainActor func resumeLifecycleRunsOnceAndPersistsHandledReceipt() async throws {
    let suite = "resume-store-\(UUID())", root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    var runs = 0
    let base = resumeFixture()
    let store = CLIResumeStore(home: root, defaults: defaults, automatic: false, lockDirectory: root,
        inspector: { _, _, _ in var result = base; result.checkedAt = Date(); return result },
        runner: { _, ticket, started in runs += 1; #expect(ticket.sandbox == "read-only"); started() })
    store.prepare(resumeThread); try await Task.sleep(for: .milliseconds(100))
    try store.arm(resumeThread, message: "继续", allowWorkspaceWrite: false)
    try await Task.sleep(for: .milliseconds(10))
    store.checkNow(resumeThread); try await Task.sleep(for: .milliseconds(150))
    #expect(runs == 1 && store.tickets[resumeThread]?.phase == .finished)
    store.checkNow(resumeThread); try await Task.sleep(for: .milliseconds(50))
    #expect(runs == 1)
    #expect(defaults.stringArray(forKey: "cliResume.handled.v1")?.count == 1)
    await store.shutdown()
}
@Test @MainActor func resumeArmedBeforeExhaustionWaitsForNewQuotaEvidence() async throws {
    let suite = "resume-armed-\(UUID())", root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    var exhausted = false; var runs = 0
    let base = resumeFixture()
    let store = CLIResumeStore(home: root, defaults: defaults, automatic: false, lockDirectory: root,
        inspector: { _, _, _ in var result = base; result.quotaPaused = exhausted; result.checkedAt = Date(); return result },
        runner: { _, _, _ in runs += 1 })
    store.prepare(resumeThread); try await Task.sleep(for: .milliseconds(80))
    try store.arm(resumeThread, message: "继续", allowWorkspaceWrite: false)
    #expect(store.tickets[resumeThread]?.phase == .armed)
    exhausted = true; store.checkNow(resumeThread)
    try await Task.sleep(for: .milliseconds(80))
    #expect(runs == 0 && store.tickets[resumeThread]?.phase == .waiting)
    await store.shutdown()
}
@Test @MainActor func resumeAccountMismatchDoesNotLaunchAndUnknownOutcomeDoesNotRetry() async throws {
    let suite = "resume-change-\(UUID())", root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    var changed = false; var runs = 0; let base = resumeFixture()
    let store = CLIResumeStore(home: root, defaults: defaults, automatic: false, lockDirectory: root,
        inspector: { _, _, _ in var result = base; result.checkedAt = Date(); if changed { result.identity.workspaceID = "other" }; return result },
        runner: { _, _, _ in runs += 1; throw CLIResumeError.unknownOutcome })
    store.prepare(resumeThread); try await Task.sleep(for: .milliseconds(80)); try store.arm(resumeThread, message: "继续", allowWorkspaceWrite: false)
    changed = true; store.checkNow(resumeThread); try await Task.sleep(for: .milliseconds(100))
    #expect(runs == 0 && store.tickets[resumeThread]?.phase == .attention)
    changed = false; store.prepare(resumeThread); try await Task.sleep(for: .milliseconds(80)); try store.arm(resumeThread, message: "继续", allowWorkspaceWrite: false)
    store.checkNow(resumeThread); try await Task.sleep(for: .milliseconds(100))
    #expect(runs == 1 && store.tickets[resumeThread]?.phase == .attention)
    store.checkNow(resumeThread); try await Task.sleep(for: .milliseconds(50)); #expect(runs == 1)
    await store.shutdown()
}
@Test @MainActor func cancellingResumeCheckPreventsLateLaunch() async throws {
    let suite = "resume-cancel-\(UUID())", root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
    var runs = 0; let base = resumeFixture()
    let store = CLIResumeStore(home: root, defaults: defaults, automatic: false,
        inspector: { _, _, _ in try? await Task.sleep(for: .milliseconds(100)); return base },
        runner: { _, _, _ in runs += 1 })
    store.prepare(resumeThread); store.cancel(resumeThread)
    try await Task.sleep(for: .milliseconds(150))
    #expect(store.prepared[resumeThread] == nil && runs == 0)
    await store.shutdown()
}

private func makeResumeProcessFixture(_ root: URL, appServer: Bool) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("fake-codex")
    let body = appServer ? """
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}';;
        *'config/read'*) printf '%s\\n' '{"id":5,"result":{"config":{}}}';;
        *'thread/read'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"\(resumeThread)","cwd":"/tmp","modelProvider":"openai","status":{"type":"notLoaded"}}}}';;
        *'thread/turns/list'*) printf '%s\\n' '{"id":3,"result":{"data":[{"id":"turn-fixture","status":"failed","error":{"codexErrorInfo":"usageLimitExceeded"}}]}}';;
      esac
    done
    """ : """
    printf '%s\\n' "$@" > '\(root.path)/arguments'
    IFS= read -r input
    printf '%s' "$input" > '\(root.path)/prompt'
    printf '%s\\n' '{"type":"thread.started","thread_id":"\(resumeThread)"}' '{"type":"turn.started"}' '{"type":"turn.completed","usage":{}}'
    """
    try ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath: file.path)
    return file
}
@Test @MainActor func cliReadOnlyProbeUsesNativeProcessAndDoesNotResumeOrStartTurn() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeResumeProcessFixture(root, appServer: true)
    let result = try await CLIResumeTransport(executablePath: executable.path, inspectTimeout: 3).lastTurn(home: root, context: resumeFixture().context)
    #expect(result.0 == "turn-fixture" && result.1 && result.2 == "failed")
}
@Test @MainActor func cliRunnerActuallyPassesExactSessionAndPromptWithoutShell() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeResumeProcessFixture(root, appServer: false)
    let sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let payload = try JSONSerialization.data(withJSONObject: ["sub":"user-fixture", "email":"fixture@example.invalid"])
    let jwt = "header." + payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".signature"
    try JSONSerialization.data(withJSONObject: ["auth_mode":"chatgpt", "tokens":["access_token":"synthetic-only", "account_id":"workspace-fixture", "id_token":jwt]])
        .write(to: root.appendingPathComponent("auth.json"))
    let records: [[String:Any]] = [
        ["type":"session_meta", "payload":["id":resumeThread, "model_provider":"openai"]],
        ["type":"turn_context", "payload":["cwd":"/tmp", "model":"gpt-test", "approval_policy":"on-request", "sandbox_policy":["type":"read-only"]]]]
    var log = Data()
    for record in records { log.append(try JSONSerialization.data(withJSONObject: record)); log.append(10) }
    try log.write(to: sessions.appendingPathComponent("rollout-\(resumeThread).jsonl"))
    let context = try CLIResumeNativeFiles.context(home: root, threadID: resumeThread)
    let identity = try CLIResumeNativeFiles.auth(home: root).0
    let ticket = CLIResumeTicket(context: context, identity: identity, turnID: "turn-fixture", observedAt: Date(),
        blockedWindows: [], message: "继续测试 $(不要作为 shell 执行)", sandbox: "read-only")
    try await CLIResumeTransport(executablePath: executable.path, runTimeout: 3).run(home: root, ticket: ticket, onStarted: {})
    let args = try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8)
    #expect(args.contains(resumeThread))
    #expect(!args.contains(ticket.message) && !args.contains("--last"))
    #expect(try String(contentsOf: root.appendingPathComponent("prompt"), encoding: .utf8) == ticket.message)
}
