import Foundation
import Testing
@testable import CodexNotch

@Test func radarFourTaskScoresUseOfficialWeightsAndCompleteSamples() throws {
    let round = try CodexRadarCurrentRound.decode(radarCurrentRoundFixture(), fetchedAt: radarScoreDate)
    #expect(round.models.count == 2)
    #expect(round.models[0].score == 112.5)
    #expect(round.models[1].score == 75)
    #expect(round.models[0].costUSD == 2.5)
    #expect(round.models[0].averageMinutes == 2.5)
    #expect(round.models[1].costUSD == nil)
    #expect(round.models[1].averageMinutes == nil)
    #expect(round.snapshot().dataSource == .publicCurrentRound)
    #expect(round.snapshot().dataSource.usesRadarScale)
    #expect(round.snapshot().displayUpdatedAt != radarScoreDate)
    #expect(round.snapshot(cached: true).models.allSatisfy { $0.status == "缓存" })

    // 合成数值覆盖 reward 的 0...1 尺度、视觉 0...100 尺度和布尔题。
    let data = try changingRound { value in
        var rows = value["rows"] as! [[String: Any]]
        rows[0]["combined"] = ["score": 58]
        rows[0]["pompeii"] = ["reward": 6.0 / 13]
        rows[0]["pelican"] = ["score": 81.5]
        rows[0]["candy"] = ["correct": true]
        value["rows"] = rows
    }
    let weighted = try CodexRadarCurrentRound.decode(data, fetchedAt: radarScoreDate)
    #expect(abs(try #require(weighted.models.first?.score) - 96.40673076923078) < 0.0000001)
}

@Test func radarFourTaskRejectsUnknownIncompleteAndMixedRounds() throws {
    let invalid: [Data] = try [
        changingRound { $0["schema"] = "unknown/2" },
        changingRound { $0["publication_contract"] = "codex-four-unknown/1" },
        changingRound { $0["publication_status"] = "partial" },
        changingRound { $0["protocol"] = "codex-four-weighted-100-v1" },
        changingRound { $0["round_id"] = "radar-bench-final64-20261004" },
        changingRound { $0["all_graded"] = false },
        changingRound { $0["graded"] = 7 },
        changingRound { $0["score_max"] = 100 },
        changingRound { $0["task_weights"] = ["combined": 75, "pompeii": 25, "pelican": 25, "candy": 25] },
        changingRound { $0["score_snapshot_at"] = "2099-01-01T00:00:00Z" },
        changingRound { $0["model_efforts"] = ["gpt-example": ["max", "max"]] },
        changingRound { value in
            var rows = value["rows"] as! [[String: Any]]
            rows[1] = rows[0]
            value["rows"] = rows
        },
        changingRound { value in
            var rows = value["rows"] as! [[String: Any]]
            rows[0].removeValue(forKey: "candy")
            value["rows"] = rows
        },
        changingRound { value in
            var rows = value["rows"] as! [[String: Any]]
            rows[0]["pompeii"] = ["reward": 1, "score100": 1]
            value["rows"] = rows
        },
        changingRound { value in
            var rows = value["rows"] as! [[String: Any]]
            rows[0]["combined"] = ["score": 101]
            value["rows"] = rows
        }
    ]
    for data in invalid {
        #expect(throws: (any Error).self) { try CodexRadarCurrentRound.decode(data, fetchedAt: radarScoreDate) }
    }
}

@Test func radarFourTaskAcceptsCompleteEventPublicationsAndValidatesTheirCache() throws {
    let data = try changingRound { $0["publication_contract"] = "codex-four-accepted-event/1" }
    let round = try CodexRadarCurrentRound.decode(data, fetchedAt: radarScoreDate)
    #expect(round.models.count == 2)
    #expect(round.models.first?.score == 112.5)
    #expect(try CodexRadarCurrentRoundCache(data: data, round: round).validatedRound().models == round.models)
    for key in ["all_graded", "graded", "publication_status"] {
        let incomplete = try changingRound { value in
            value["publication_contract"] = "codex-four-accepted-event/1"
            switch key {
            case "all_graded": value[key] = false
            case "graded": value[key] = 7
            default: value[key] = "partial"
            }
        }
        #expect(throws: (any Error).self) { try CodexRadarCurrentRound.decode(incomplete, fetchedAt: radarScoreDate) }
    }
}

@Test func radarFourTaskCacheValidatesItsProtocolAndRoundIdentity() throws {
    let data = radarCurrentRoundFixture()
    let round = try CodexRadarCurrentRound.decode(data, fetchedAt: radarScoreDate)
    let cache = CodexRadarCurrentRoundCache(data: data, round: round)
    #expect(try cache.validatedRound().models == round.models)
    var serialized = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as? [String: Any])
    serialized["roundID"] = "codex-four-another-round"
    let altered = try JSONDecoder().decode(CodexRadarCurrentRoundCache.self,
        from: JSONSerialization.data(withJSONObject: serialized))
    #expect(throws: (any Error).self) { try altered.validatedRound() }
}

@Test func radarCurrentRoundEndpointIsPublicAndRetryAfterIsStructured() async throws {
    let client = CodexRadarClient { request in
        #expect(request.url == CodexRadarClient.currentRoundURL)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Radar-Bench-Selection") == nil)
        #expect(!request.httpShouldHandleCookies)
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                                      headerFields: ["Retry-After": "900"])!)
    }
    do { _ = try await client.fetchCurrentRound(); Issue.record("Expected HTTP 429") }
    catch let error as CodexRadarClientError {
        #expect(error.retryAfter == 900)
        #expect(error.isServiceUnavailable)
        #expect(error.errorDescription?.contains("429") == true)
    }
    #expect(!CodexRadarClient.isAllowed(URL(string: CodexRadarClient.currentRoundURL.absoluteString + "?token=bad")!, authorized: false))
    #expect(CodexRadarClient.retryAfter("-5") == nil)
    #expect(CodexRadarClient.retryAfter("inf") == nil)
    #expect(CodexRadarClient.retryAfter("Wed, 21 Oct 2015 07:28:00 GMT",
        now: ISO8601DateFormatter().date(from: "2015-10-21T07:27:00Z")!) == 60)
}

@Test func radarOldGatewayFailureStopsQueuedModelRequests() async throws {
    let transport = CurrentRoundTransport()
    var binding = try #require(JSONSerialization.jsonObject(with: radarBindingFixture()) as? [String: Any])
    binding["model_efforts"] = (1...12).map { ["model": "gpt-synthetic-\($0)", "effort": "high"] }
    await transport.setBinding(try JSONSerialization.data(withJSONObject: binding))
    await transport.fail(CodexRadarClient.benchURL.path, status: 502, retryAfter: "60")
    let client = CodexRadarClient { try await transport.send($0) }
    let batch = try await client.fetchBench()
    #expect(batch.results.count == 12)
    #expect(batch.retryAfter == 60)
    #expect(await transport.count(CodexRadarClient.benchURL.path) <= 3)
    let snapshot = CodexRadarBenchCache.merging(batch.decode(fetchedAt: radarScoreDate), previous: nil,
        checkedAt: radarScoreDate).snapshot(for: .software, failure: nil)
    #expect(snapshot.message?.components(separatedBy: "HTTP 502").count == 2)
    #expect(snapshot.message?.contains("影响 12 个配置") == true)
}

@MainActor @Suite struct CodexRadarCurrentRoundLifecycleTests {
    @Test func currentTotalRemainsReadyWhenOldBenchFails() async throws {
        let context = try CurrentRoundContext()
        defer { context.cleanUp() }
        await context.transport.fail(CodexRadarClient.benchURL.path, status: 502, retryAfter: "60")
        let model = context.model()
        try await waitForCurrentRoundRefresh(model)
        #expect(model.snapshot.state == .ready)
        #expect(model.snapshot.dataSource == .publicCurrentRound)
        #expect(model.snapshot.models.first?.score == 112.5)
        #expect(model.snapshot.message == nil)
        #expect(model.community != nil)
        #expect(model.news != nil)
        #expect(model.combinedScores.contains { $0.id == "gpt-community-only|low" && $0.radar.score == nil })
        model.selectDimension(.software)
        #expect(model.snapshot.state == .error)
        #expect(model.snapshot.message?.contains("502") == true)
        model.selectDimension(.comprehensive)
        #expect(model.snapshot.state == .ready)
        #expect(model.snapshot.message == nil)
    }

    @Test func currentTotalFailureKeepsOnlyItsOwnRoundCache() async throws {
        let context = try CurrentRoundContext()
        defer { context.cleanUp() }
        let model = context.model()
        try await waitForCurrentRoundRefresh(model)
        let original = model.snapshot
        await context.transport.setCurrent(Data("{}".utf8))
        context.date.addTimeInterval(300)
        model.refreshNow()
        try await waitForCurrentRoundRefresh(model)
        #expect(model.snapshot.state == .stale)
        #expect(model.snapshot.models.map(\.score) == original.models.map(\.score))
        #expect(model.snapshot.fetchedAt == original.fetchedAt)
        #expect(model.snapshot.displayUpdatedAt == original.displayUpdatedAt)
        #expect(model.snapshot.models.allSatisfy { $0.status == "缓存" })
        #expect(model.lastCheckedAt == context.date)
        model.selectDimension(.science)
        #expect(model.snapshot.dataSource == .publicBench)
        #expect(model.snapshot.models.first?.score == 50)
        model.selectDimension(.comprehensive)
        var event = try #require(JSONSerialization.jsonObject(with: radarCurrentRoundFixture(roundID: "codex-four-synthetic-2")) as? [String: Any])
        event["publication_contract"] = "codex-four-accepted-event/1"
        await context.transport.setCurrent(try JSONSerialization.data(withJSONObject: event))
        context.date.addTimeInterval(300)
        model.refreshIfNeeded()
        try await waitForCurrentRoundRefresh(model)
        #expect(model.snapshot.state == .ready)
        #expect(model.snapshot.attributionText.contains("codex-four-synthetic-2"))
        let cache = try JSONDecoder().decode(CodexRadarCurrentRoundCache.self,
            from: Data(contentsOf: context.directory.appendingPathComponent("four-task-v2.json")))
        #expect(try cache.validatedRound().roundID == "codex-four-synthetic-2")
        let attributes = try FileManager.default.attributesOfItem(atPath: context.directory.appendingPathComponent("four-task-v2.json").path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func sourceRetryAfterDoesNotBlockOtherSourcesOrAllowManualHammering() async throws {
        let context = try CurrentRoundContext()
        defer { context.cleanUp() }
        await context.transport.fail(CodexRadarClient.currentRoundURL.path, status: 429, retryAfter: "900")
        let model = context.model()
        try await waitForCurrentRoundRefresh(model)
        #expect(await context.transport.count(CodexRadarClient.currentRoundURL.path) == 1)
        model.refreshNow()
        try await waitForCurrentRoundRefresh(model)
        #expect(await context.transport.count(CodexRadarClient.currentRoundURL.path) == 1)
        context.date.addTimeInterval(300)
        model.refreshIfNeeded()
        try await waitForCurrentRoundRefresh(model)
        #expect(model.community?.fetchedAt == context.date)
        #expect(await context.transport.count(CodexRadarClient.currentRoundURL.path) == 1)
        #expect(model.snapshot.message?.contains("上游要求等待至") == true)
        await context.transport.fail(CodexRadarClient.currentRoundURL.path, status: nil)
        context.date.addTimeInterval(600)
        model.refreshIfNeeded()
        try await waitForCurrentRoundRefresh(model)
        #expect(await context.transport.count(CodexRadarClient.currentRoundURL.path) == 2)
        #expect(model.snapshot.state == .ready)
    }

    @Test func fastSourcesPublishWhileOldModelRequestsAreStillRunning() async throws {
        let context = try CurrentRoundContext()
        defer { context.cleanUp() }
        await context.transport.pauseOldBench()
        let model = context.model()
        for _ in 0..<200 {
            if model.snapshot.state == .ready && model.community != nil && model.news != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.snapshot.state == .ready)
        #expect(model.community != nil)
        #expect(model.news != nil)
        #expect(model.isRefreshing)
        await context.transport.resumeOldBench()
        try await waitForCurrentRoundRefresh(model)
    }
}

private func changingRound(_ change: (inout [String: Any]) -> Void) throws -> Data {
    var value = try #require(JSONSerialization.jsonObject(with: radarCurrentRoundFixture()) as? [String: Any])
    change(&value)
    return try JSONSerialization.data(withJSONObject: value)
}

@MainActor private func waitForCurrentRoundRefresh(_ model: CodexRadarViewModel) async throws {
    for _ in 0..<300 {
        if !model.isRefreshing { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Current-round refresh did not complete")
}

private actor CurrentRoundTransport {
    private var requests: [URLRequest] = []
    private var statusCodes: [String: Int] = [:]
    private var retryHeaders: [String: String] = [:]
    private var current = radarCurrentRoundFixture()
    private var binding = radarBindingFixture()
    private var oldBenchPaused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func count(_ path: String) -> Int { requests.filter { $0.url?.path == path }.count }
    func setCurrent(_ value: Data) { current = value }
    func setBinding(_ value: Data) { binding = value }
    func pauseOldBench() { oldBenchPaused = true }
    func resumeOldBench() {
        oldBenchPaused = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
    func fail(_ path: String, status: Int?, retryAfter: String? = nil) {
        statusCodes[path] = status
        retryHeaders[path] = retryAfter
    }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url!.path
        if path == CodexRadarClient.benchURL.path, oldBenchPaused {
            await withCheckedContinuation { waiters.append($0) }
        }
        let data: Data
        switch path {
        case CodexRadarClient.currentRoundURL.path: data = current
        case CodexRadarClient.bindingURL.path: data = binding
        default: data = radarFixtureResponse(request)
        }
        let headers = retryHeaders[path].map { ["Retry-After": $0] }
        return (data, HTTPURLResponse(url: request.url!, statusCode: statusCodes[path] ?? 200,
                                      httpVersion: nil, headerFields: headers)!)
    }
}

@MainActor private final class CurrentRoundContext {
    let suite = "radar-current-round-\(UUID())"
    let defaults: UserDefaults
    let settings: CodexNotchSettings
    let directory: URL
    let transport = CurrentRoundTransport()
    var date = radarScoreDate

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "codexRadarEnabled")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        settings = CodexNotchSettings(defaults: defaults, initialManagementKey: "", initialNewAPIKey: "", initialSubAPIKey: "",
            secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
            launchAtLoginManager: CurrentRoundLaunchManager(), loadSecretsSynchronously: true)
    }
    func model() -> CodexRadarViewModel {
        let transport = transport
        return CodexRadarViewModel(settings: settings, client: CodexRadarClient { try await transport.send($0) },
                                  cacheDirectory: directory, selectionDefaults: defaults, now: { self.date })
    }
    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct CurrentRoundLaunchManager: LaunchAtLoginManaging {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws {}
}
