import Foundation
import Testing
@testable import CodexNotch

private let rateEpoch = Date(timeIntervalSince1970: 1_800_000_000)
private let rateThread = "11111111-1111-4111-8111-111111111111"
private let rateChild = "22222222-2222-4222-8222-222222222222"

private func rateDate(_ seconds: TimeInterval) -> Date { rateEpoch.addingTimeInterval(seconds) }
private func rateEvent(_ kind: CodexTokenRateEvent.Kind, at seconds: TimeInterval,
                       owner: String? = nil) -> CodexTokenRateEvent {
    .init(date: rateDate(seconds), threadID: owner, kind: kind)
}
private func rateClose(_ value: Double?, _ expected: Double) -> Bool {
    guard let value else { return false }
    // Date 的 Double 时间戳在亚秒样本中会有微小舍入误差。
    return abs(value - expected) < 0.000_1
}
private func rateState() -> CodexTokenRateState {
    var state = CodexTokenRateState(threadID: rateThread)
    state.consume(rateEvent(.start(turnID: "turn-a"), at: 0))
    return state
}
private func rateJSON(_ type: String, at seconds: TimeInterval, _ payload: [String: Any]) throws -> Data {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return try JSONSerialization.data(withJSONObject: [
        "timestamp": formatter.string(from: rateDate(seconds)), "type": type, "payload": payload
    ], options: [.sortedKeys])
}
private func rateUsage(total: Int, last: Int) -> [String: Any] {
    ["type": "token_count", "info": [
        "total_token_usage": ["output_tokens": total, "input_tokens": 9_000_000, "cached_input_tokens": 8_000_000],
        "last_token_usage": ["output_tokens": last, "reasoning_output_tokens": last / 2,
                             "input_tokens": 1_000_000, "cached_input_tokens": 900_000]
    ]]
}
private func rateLog(output: Int = 600, start: TimeInterval = 0, end: TimeInterval = 10) throws -> [Data] {
    [
        try rateJSON("session_meta", at: start, ["id": rateThread, "source": "cli"]),
        try rateJSON("event_msg", at: start, ["type": "task_started", "turn_id": "turn-a"]),
        try rateJSON("response_item", at: end, ["type": "message", "role": "assistant", "content": "合成输出"]),
        try rateJSON("event_msg", at: end, rateUsage(total: output, last: output))
    ]
}
private func rateLines(_ lines: [Data]) -> Data {
    var result = Data()
    for line in lines { result.append(line); result.append(0x0A) }
    return result
}
private func rateDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("token-rate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
private func appendRateData(_ data: Data, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}

@Test func tokenRateCountsOutputOnceAndExcludesInput() throws {
    let decoder = CodexTokenRateEventDecoder()
    var state = CodexTokenRateState(threadID: rateThread)
    for line in try rateLog() { state.consume(try #require(decoder.decode(line))) }
    let sample = try #require(state.sample)
    #expect(rateClose(sample.value, 60))
    #expect(!sample.isEstimate)
    #expect(sample.measuredAt == rateDate(10))
}

@Test func tokenRateAuthoritativeUsageReplacesSameRequestAndDeduplicates() throws {
    var state = rateState()
    state.consume(rateEvent(.output, at: 10))
    state.consume(rateEvent(.usage(total: 600, last: 600, reasoning: 300, cached: false), at: 10))
    state.consume(rateEvent(.request(id: "response-a", turnID: "turn-a", output: 750, reasoning: 300), at: 10.2, owner: rateThread))
    #expect(rateClose(state.sample?.value, 75))
    state.consume(rateEvent(.request(id: "response-a", turnID: "turn-a", output: 9_999, reasoning: nil), at: 11, owner: rateThread))
    #expect(rateClose(state.sample?.value, 75))
    #expect(state.sample?.measuredAt == rateDate(10))
    state.consume(rateEvent(.output, at: 20))
    state.consume(rateEvent(.request(id: "response-b", turnID: "turn-a", output: 500, reasoning: nil), at: 20, owner: rateThread))
    #expect(rateClose(state.sample?.value, 50))
}

@Test func tokenRateRepeatedCounterDoesNotRefreshAgeOrShortenNextWindow() {
    var state = rateState()
    state.consume(rateEvent(.output, at: 10))
    state.consume(rateEvent(.usage(total: 600, last: 600, reasoning: nil, cached: false), at: 10))
    state.consume(rateEvent(.usage(total: 600, last: 600, reasoning: nil, cached: false), at: 20))
    #expect(state.sample?.measuredAt == rateDate(10))
    state.consume(rateEvent(.output, at: 30))
    state.consume(rateEvent(.usage(total: 1_200, last: 600, reasoning: nil, cached: false), at: 30))
    #expect(rateClose(state.sample?.value, 30))
}

@Test func tokenRateDelayedUsageStillPrefersItsSettledRequestWindow() {
    var state = rateState()
    state.consume(rateEvent(.output, at: 10))
    state.consume(rateEvent(.usage(total: 600, last: 600, reasoning: nil, cached: false), at: 10))
    state.consume(rateEvent(.output, at: 20))
    state.consume(rateEvent(.usage(total: 1_200, last: 600, reasoning: nil, cached: false), at: 23))
    #expect(rateClose(state.sample?.value, 60))
    #expect(state.sample?.isEstimate == false)
    #expect(state.sample?.measuredAt == rateDate(20))
    // 后续无新计数的事件也不能重新把同一份 fallback 当成新读数。
    state.consume(rateEvent(.ownedBoundary, at: 24, owner: rateThread))
    #expect(rateClose(state.sample?.value, 60))
    #expect(state.sample?.isEstimate == false)
}

@Test func tokenRateCachedUsageAloneCannotCreateARequest() {
    var state = rateState()
    state.consume(rateEvent(.usage(total: 600, last: 600, reasoning: nil, cached: true), at: 10))
    state.consume(rateEvent(.usage(total: 600, last: 600, reasoning: nil, cached: false), at: 20))
    #expect(state.sample == nil)
    state.consume(rateEvent(.output, at: 30))
    state.consume(rateEvent(.usage(total: 1_200, last: 600, reasoning: nil, cached: false), at: 30))
    #expect(state.sample?.measuredAt == rateDate(30))
}

@Test func tokenRateConfirmedToolWaitIsExcludedFromNextRequest() {
    var state = rateState()
    state.consume(rateEvent(.toolStart("call-a"), at: 10))
    state.consume(rateEvent(.usage(total: 600, last: 600, reasoning: nil, cached: false), at: 10))
    #expect(rateClose(state.sample?.value, 60))
    #expect(state.sample?.isWaiting == true)
    state.consume(rateEvent(.toolEnd("call-a"), at: 100))
    state.consume(rateEvent(.output, at: 110))
    state.consume(rateEvent(.usage(total: 1_200, last: 600, reasoning: nil, cached: false), at: 110))
    #expect(rateClose(state.sample?.value, 60))
    #expect(state.sample?.isWaiting == false)
}

@Test func tokenRateParallelToolWaitEndsOnlyAfterFinalBlockingResult() {
    var state = rateState()
    state.consume(rateEvent(.toolStart("call-a"), at: 10))
    state.consume(rateEvent(.toolStart("call-b"), at: 10))
    state.consume(rateEvent(.usage(total: 600, last: 600, reasoning: nil, cached: false), at: 10))
    state.consume(rateEvent(.toolEnd("call-a"), at: 20))
    #expect(state.sample?.isWaiting == true)
    state.consume(rateEvent(.toolEnd("call-b"), at: 30))
    state.consume(rateEvent(.output, at: 40))
    state.consume(rateEvent(.usage(total: 1_200, last: 600, reasoning: nil, cached: false), at: 40))
    #expect(rateClose(state.sample?.value, 60))
}

@Test func tokenRateBackgroundResultCannotRestartAnAlreadyResumedWindow() {
    var state = rateState()
    state.consume(rateEvent(.toolStart("background"), at: 10))
    state.consume(rateEvent(.usage(total: 600, last: 600, reasoning: nil, cached: false), at: 10))
    state.consume(rateEvent(.output, at: 20))
    state.consume(rateEvent(.toolEnd("background"), at: 30))
    state.consume(rateEvent(.output, at: 40))
    state.consume(rateEvent(.usage(total: 1_200, last: 600, reasoning: nil, cached: false), at: 40))
    // 第二次请求起点缺失时使用较新的增量估算；后台返回不能制造 30...40 的短窗口。
    #expect(rateClose(state.sample?.value, 30))
    #expect(state.sample?.isEstimate == true)
    #expect(state.sample?.measuredAt == rateDate(40))
}

@Test func tokenRateNewTurnRejectsPreviousTurnUsageAndTerminalEvents() {
    var state = rateState()
    state.consume(rateEvent(.output, at: 10))
    state.consume(rateEvent(.request(id: "old-response", turnID: "turn-a", output: 600, reasoning: nil), at: 10, owner: rateThread))
    state.consume(rateEvent(.start(turnID: "turn-b"), at: 20))
    #expect(state.sample == nil)
    state.consume(rateEvent(.request(id: "late-response", turnID: "turn-a", output: 9_000, reasoning: nil), at: 25, owner: rateThread))
    state.consume(rateEvent(.finish(turnID: "turn-a"), at: 26))
    #expect(state.sample == nil)
    state.consume(rateEvent(.output, at: 30))
    state.consume(rateEvent(.request(id: "new-response", turnID: "turn-b", output: 400, reasoning: nil), at: 30, owner: rateThread))
    #expect(rateClose(state.sample?.value, 40))
    #expect(state.sample?.isFinished == false)
}

@Test func tokenRateLateAccountingMayRefineFinishedRequestWithoutRevivingIt() {
    var state = rateState()
    state.consume(rateEvent(.output, at: 10))
    state.consume(rateEvent(.usage(total: 600, last: 600, reasoning: nil, cached: false), at: 10))
    state.consume(rateEvent(.finish(turnID: "turn-a"), at: 11))
    state.consume(rateEvent(.request(id: "late-exact", turnID: "turn-a", output: 750, reasoning: nil), at: 12, owner: rateThread))
    #expect(rateClose(state.sample?.value, 75))
    #expect(state.sample?.isFinished == true)
}

@Test func tokenRateForeignAccountingCannotAffectCurrentThread() {
    var state = rateState()
    state.consume(rateEvent(.output, at: 10))
    state.consume(rateEvent(.request(id: "foreign", turnID: "turn-a", output: 9_000, reasoning: nil), at: 10, owner: rateChild))
    #expect(state.sample == nil)
    state.consume(rateEvent(.request(id: "own", turnID: "turn-a", output: 600, reasoning: nil), at: 10, owner: rateThread))
    #expect(rateClose(state.sample?.value, 60))
}

@Test func tokenRateFallbackNeedsTwoCountersAndRetainsFullBurstInterval() {
    var rate = GenerationRate()
    rate.start()
    rate.observe(total: 1_000, at: rateDate(0))
    #expect(rate.estimate(at: rateDate(0)) == nil)
    rate.observe(total: 1_010, at: rateDate(0.1))
    #expect(rate.estimate(at: rateDate(0.1)) == nil)
    rate.observe(total: 1_040, at: rateDate(0.4))
    #expect(rateClose(rate.estimate(at: rateDate(0.4))?.value, 100))
    rate.observe(total: 1_040, at: rateDate(5))
    #expect(rate.estimate(at: rateDate(5))?.reportedAt == rateDate(0.4))
    #expect(rate.estimate(at: rateDate(16)) == nil)
}

@Test func tokenRateFallbackCounterResetSeedsRatherThanSpikes() {
    var rate = GenerationRate()
    rate.start()
    rate.observe(total: 1_000, at: rateDate(0))
    rate.observe(total: 1_600, at: rateDate(10))
    #expect(rateClose(rate.estimate(at: rateDate(10))?.value, 60))
    rate.observe(total: 10, at: rateDate(11))
    #expect(rate.estimate(at: rateDate(11)) == nil)
    rate.observe(total: 610, at: rateDate(21))
    #expect(rateClose(rate.estimate(at: rateDate(21))?.value, 60))
}

@Test func tokenRateCounterResetInvalidatesAnOlderSettledWindow() {
    var state = rateState()
    state.consume(rateEvent(.output, at: 10))
    state.consume(rateEvent(.usage(total: 1_000, last: 600, reasoning: nil, cached: false), at: 10))
    #expect(rateClose(state.sample?.value, 60))
    state.consume(rateEvent(.usage(total: 0, last: 0, reasoning: nil, cached: false), at: 20))
    #expect(state.sample == nil)
    state.consume(rateEvent(.output, at: 30))
    state.consume(rateEvent(.usage(total: 600, last: 600, reasoning: nil, cached: false), at: 30))
    #expect(rateClose(state.sample?.value, 60))
    #expect(state.sample?.isEstimate == true)
}

@Test func tokenRateFallbackExcludesUnionOfToolWaits() {
    var rate = GenerationRate()
    rate.start()
    rate.observe(total: 100, at: rateDate(0))
    rate.setWaiting(true, at: rateDate(2))
    rate.setWaiting(true, at: rateDate(4))
    rate.setWaiting(false, at: rateDate(12))
    rate.observe(total: 700, at: rateDate(20))
    #expect(rateClose(rate.estimate(at: rateDate(20))?.value, 60))
}

@Test func tokenRateDecoderRejectsBooleanFractionalAndNegativeCounters() throws {
    let decoder = CodexTokenRateEventDecoder()
    let invalidCounters: [Any] = [true, -1, 1.5]
    for invalid in invalidCounters {
        let data = try rateJSON("event_msg", at: 10, ["type": "token_count", "info": [
            "total_token_usage": ["output_tokens": invalid], "last_token_usage": ["output_tokens": 600]
        ]])
        #expect(decoder.decode(data) == nil)
    }
    #expect(decoder.decode(Data("invalid json".utf8)) == nil)
}

@Test func tokenRateDecoderKeepsOpaqueResponseIDsDistinct() throws {
    let decoder = CodexTokenRateEventDecoder()
    var state = rateState()
    state.consume(rateEvent(.output, at: 10))
    let first = try rateJSON("token_usage_record", at: 10, [
        "thread_id": rateThread, "turn_id": "turn-a", "response_id": "Resp-A", "usage": ["output_tokens": 600]
    ])
    state.consume(try #require(decoder.decode(first)))
    state.consume(rateEvent(.output, at: 20))
    let second = try rateJSON("token_usage_record", at: 20, [
        "thread_id": rateThread, "turn_id": "turn-a", "response_id": "resp-a", "usage": ["output_tokens": 900]
    ])
    state.consume(try #require(decoder.decode(second)))
    #expect(rateClose(state.sample?.value, 90))
}

@Test func tokenRateWorldStateWithoutTimestampStillResetsInheritedUsage() throws {
    let decoder = CodexTokenRateEventDecoder()
    var state = rateState()
    state.consume(rateEvent(.output, at: 10))
    state.consume(rateEvent(.usage(total: 600, last: 600, reasoning: nil, cached: false), at: 10))
    #expect(state.sample != nil)
    let reset = try #require(decoder.decode(Data(#"{"type":"world_state","payload":{}}"#.utf8)))
    state.consume(reset)
    #expect(state.sample == nil)
}

@Test func tokenRateChildIgnoresInheritedParentHistory() {
    var state = CodexTokenRateState(threadID: rateChild)
    state.consume(rateEvent(.metadata(threadID: rateChild, parentID: rateThread, internalReview: false), at: 0))
    state.consume(rateEvent(.metadata(threadID: rateThread, parentID: nil, internalReview: false), at: 1))
    state.consume(rateEvent(.start(turnID: "inherited-turn"), at: 2))
    state.consume(rateEvent(.output, at: 10))
    state.consume(rateEvent(.usage(total: 9_000, last: 9_000, reasoning: nil, cached: false), at: 10))
    #expect(state.sample == nil)
    #expect(state.threadID == rateChild)
    #expect(state.parentThreadID == rateThread)
    state.consume(rateEvent(.start(turnID: "own-turn"), at: 20, owner: rateChild))
    state.consume(rateEvent(.output, at: 30))
    state.consume(rateEvent(.usage(total: 400, last: 400, reasoning: nil, cached: false), at: 30))
    #expect(rateClose(state.sample?.value, 40))
}

private func rateSample(_ thread: String, value: Double, at seconds: TimeInterval,
                        parent: String? = nil, waiting: Bool = false, finished: Bool = false,
                        review: Bool = false, estimate: Bool = false) -> TokenRateTaskSample {
    .init(threadID: thread, parentThreadID: parent, value: value, measuredAt: rateDate(seconds),
          isEstimate: estimate, isWaiting: waiting, isFinished: finished, isInternalReview: review)
}

@Test func tokenRateAggregationCountsEachOwnOutputOnceAndExcludesReviews() {
    let samples = [
        rateSample(rateThread, value: 60, at: 10),
        rateSample(rateThread, value: 20, at: 9),
        rateSample(rateChild, value: 40, at: 11, parent: rateThread),
        rateSample("review", value: 900, at: 11, parent: rateThread, review: true),
        rateSample("waiting", value: 500, at: 11, parent: rateThread, waiting: true),
        rateSample("unrelated", value: 300, at: 11)
    ]
    let summary = TokenRateSummary.aggregate(samples, activeThreadIDs: [rateThread], expectedActiveCount: 3, now: rateDate(12))
    #expect(rateClose(summary.value, 100))
    #expect(summary.measuredCount == 2)
    #expect(summary.activeCount == 3)
    #expect(summary.isFresh(at: rateDate(12)))
    #expect(summary.explanation(at: rateDate(12)).contains("2/3"))
}

@Test func tokenRateAggregationIncludesNestedSubagentsWithoutDoubleCounting() {
    let samples = [
        rateSample(rateThread, value: 10, at: 10),
        rateSample(rateChild, value: 20, at: 10, parent: rateThread),
        rateSample("grandchild", value: 30, at: 10, parent: rateChild)
    ]
    let summary = TokenRateSummary.aggregate(samples, activeThreadIDs: [rateThread], expectedActiveCount: 3, now: rateDate(11))
    #expect(rateClose(summary.value, 60))
    #expect(summary.measuredCount == 3)
}

@Test func tokenRateAggregationDoesNotSumOldRequestsAsCurrentSpeed() {
    let samples = [rateSample(rateThread, value: 60, at: 10), rateSample(rateChild, value: 40, at: 12, parent: rateThread)]
    let summary = TokenRateSummary.aggregate(samples, activeThreadIDs: [rateThread], expectedActiveCount: 2, now: rateDate(40))
    #expect(rateClose(summary.value, 40))
    #expect(summary.isStale)
    #expect(!summary.isFresh(at: rateDate(40)))
    #expect(summary.measuredCount == 1)
}

@Test func tokenRateUnavailableIsNotZeroAndFutureSamplesAreNotFresh() {
    let empty = TokenRateSummary.aggregate([], activeThreadIDs: [rateThread], expectedActiveCount: 1, now: rateDate(10))
    #expect(empty.value == nil)
    #expect(empty.formatted(at: rateDate(10)) == "— token/s")
    let future = TokenRateSummary.aggregate([rateSample(rateThread, value: 60, at: 20)],
        activeThreadIDs: [rateThread], expectedActiveCount: 1, now: rateDate(10))
    #expect(future.value == nil)
    let estimate = TokenRateSummary(value: 60, measuredAt: rateDate(10), isEstimate: true, measuredCount: 1, activeCount: 1)
    #expect(estimate.formatted(at: rateDate(10)) == "≈60.0 token/s")
}

@Test func tokenRateReaderWaitsForCompleteLineAndDoesNotReplayUnchangedFiles() async throws {
    let directory = try rateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("rollout-\(rateThread).jsonl")
    let lines = try rateLog()
    let usage = lines[3], split = usage.count / 2
    var beginning = rateLines(Array(lines.prefix(3)))
    beginning.append(usage.prefix(split))
    try beginning.write(to: file)
    let reader = CodexTokenRateReader()
    #expect(await reader.read(paths: [file.path]).isEmpty)
    var remainder = Data(usage.dropFirst(split)); remainder.append(0x0A)
    try appendRateData(remainder, to: file)
    let first = await reader.read(paths: [file.path])
    #expect(first.count == 1)
    #expect(rateClose(first.first?.value, 60))
    let repeated = await reader.read(paths: [file.path, file.path])
    #expect(repeated == first)
    try appendRateData(rateLines([try rateJSON("event_msg", at: 20, rateUsage(total: 600, last: 600))]), to: file)
    let duplicate = await reader.read(paths: [file.path])
    #expect(duplicate.first?.measuredAt == rateDate(10))
}

@Test func tokenRateReaderResetsAfterTruncationAndAtomicReplacement() async throws {
    let directory = try rateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("rollout-\(rateThread).jsonl")
    try rateLines(rateLog()).write(to: file)
    let reader = CodexTokenRateReader()
    #expect(rateClose(await reader.read(paths: [file.path]).first?.value, 60))
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: rateLines(Array(try rateLog(output: 300).prefix(2))))
    try handle.close()
    #expect(await reader.read(paths: [file.path]).isEmpty)
    try rateLines(rateLog(output: 300, start: 20, end: 30)).write(to: file, options: .atomic)
    #expect(rateClose(await reader.read(paths: [file.path]).first?.value, 30))
}

@Test func tokenRateReaderDetectsSameInodeSameLengthRewrite() async throws {
    let directory = try rateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("rollout-\(rateThread).jsonl")
    let original = try rateLines(rateLog(output: 600))
    let replacement = try rateLines(rateLog(output: 300))
    #expect(original.count == replacement.count)
    try original.write(to: file)
    let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
    let reader = CodexTokenRateReader()
    #expect(rateClose(await reader.read(paths: [file.path]).first?.value, 60))
    let handle = try FileHandle(forWritingTo: file)
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: replacement)
    try handle.close()
    let rewrittenInode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
    #expect(inode == rewrittenInode)
    #expect(rateClose(await reader.read(paths: [file.path]).first?.value, 30))
}

@Test func tokenRateReaderDropsRemovedPathsAndIgnoresNonLogInputs() async throws {
    let directory = try rateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("rollout-\(rateThread).jsonl")
    let other = directory.appendingPathComponent("private.txt")
    try rateLines(rateLog()).write(to: file)
    try rateLines(rateLog(output: 900)).write(to: other)
    let reader = CodexTokenRateReader()
    #expect(await reader.read(paths: [file.path, other.path]).count == 1)
    #expect(await reader.read(paths: [other.path]).isEmpty)
    try FileManager.default.removeItem(at: file)
    #expect(await reader.read(paths: [file.path]).isEmpty)
}
