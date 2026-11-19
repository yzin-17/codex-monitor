import Combine
import Darwin
import Foundation

@MainActor
final class CodexRadarViewModel: ObservableObject {
    @Published private(set) var snapshot: CodexRadarSnapshot = .disabled
    @Published private(set) var news: CodexRadarNewsSnapshot?
    @Published private(set) var newsMessage: String?
    @Published private(set) var selectedDimension: CodexRadarDimension
    @Published private(set) var isRefreshing = false
    @Published private(set) var nextRefreshAt: Date?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var community: CodexRadarCommunitySnapshot?
    @Published private(set) var communityMessage: String?
    @Published private(set) var scoreSort: CodexRadarScoreSort

    private let settings: CodexNotchSettings
    private let client: CodexRadarClient
    private let cacheDirectory: URL
    private let selectionDefaults: UserDefaults
    private let now: @MainActor () -> Date
    private var softwareSnapshot: CodexRadarSnapshot = .loading
    private var visualSnapshot: CodexRadarSnapshot = .loading
    private var authorizedSnapshot: CodexRadarSnapshot?
    private var benchCache: CodexRadarBenchCache?
    private var benchCacheMessage: String?
    private var currentRound: CodexRadarCurrentRound?
    private var currentRoundCache: CodexRadarCurrentRoundCache?
    private var currentRoundMessage: String?
    private enum Feed: CaseIterable, Hashable, Sendable { case currentRound, bench, community, news, authorized }
    private enum FeedResult: Sendable {
        case currentRound(Result<Data, Error>)
        case bench(Result<CodexRadarBenchBatch, Error>)
        case community(Result<Data, Error>)
        case news(Result<Data, Error>)
        case authorized(Result<Data, Error>)
    }
    private var failures: Set<Feed> = []
    private var retryDates: [Feed: Date] = [:]
    private var serverRetryDates: [Feed: Date] = [:]
    private var refreshTimer: Timer?
    private var settingsTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var generation = 0
    private var observedEnabled: Bool
    private var observedToken: String
    private var lastManualRefreshAt: Date?

    init(
        settings: CodexNotchSettings,
        client: CodexRadarClient = CodexRadarClient(),
        cacheDirectory: URL = CodexRadarCache.defaultDirectory(),
        selectionDefaults: UserDefaults = .standard,
        now: @escaping @MainActor () -> Date = Date.init,
        previewSnapshot: CodexRadarSnapshot? = nil
    ) {
        self.settings = settings
        self.client = client
        self.cacheDirectory = cacheDirectory
        self.selectionDefaults = selectionDefaults
        self.now = now
        if settings.preferenceStore.object(forKey: "codexRadarEnabled") == nil {
            settings.codexRadarEnabled = true
        }
        selectedDimension = selectionDefaults.string(forKey: "codexRadarDimension")
            .flatMap(CodexRadarDimension.init(rawValue:)) ?? .comprehensive
        scoreSort = selectionDefaults.string(forKey: "codexRadarScoreSort")
            .flatMap(CodexRadarScoreSort.init(rawValue:)) ?? .radar
        observedEnabled = settings.codexRadarEnabled
        observedToken = settings.codexRadarAPIToken
        if let previewSnapshot {
            snapshot = previewSnapshot
            lastCheckedAt = previewSnapshot.fetchedAt
            return
        }
        observeSettings()
        loadCacheAndSchedule()
    }

    func selectDimension(_ dimension: CodexRadarDimension) {
        selectedDimension = dimension
        selectionDefaults.set(dimension.rawValue, forKey: "codexRadarDimension")
        updateDisplayedSnapshot()
    }

    var combinedScores: [CodexRadarCombinedScore] {
        guard settings.codexRadarEnabled else { return [] }
        return CodexRadarCombinedScore.combine(snapshot.models, community: community, sort: scoreSort)
    }

    func selectSort(_ sort: CodexRadarScoreSort) {
        scoreSort = sort
        selectionDefaults.set(sort.rawValue, forKey: "codexRadarScoreSort")
    }

    func refreshNow() {
        guard settings.codexRadarEnabled, !isRefreshing else { return }
        guard CodexRadarRefreshPolicy.canManualRefresh(lastRefreshAt: lastManualRefreshAt, now: now()) else {
            snapshot = snapshot.withState(snapshot.state, message: "刚刚已刷新；手动刷新间隔为 5 分钟")
            return
        }
        refreshFromNetwork(manual: true)
    }

    private var oldestFetchAt: Date? {
        benchCache?.entries.map(\.fetchedAt).min()
    }

    func refreshIfNeeded() {
        guard settings.codexRadarEnabled else { return }
        if activeFeeds.contains(where: { needsRefresh($0, manual: false) }) {
            refreshFromNetwork()
        } else {
            scheduleNextRefresh()
        }
    }

    private var activeFeeds: [Feed] {
        settings.codexRadarAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [.currentRound, .bench, .community, .news] : Feed.allCases
    }

    private func fetchDate(_ feed: Feed) -> Date? {
        switch feed {
        case .currentRound: currentRound?.fetchedAt
        case .bench: oldestFetchAt
        case .community: community?.fetchedAt
        case .news: news?.fetchedAt
        case .authorized: authorizedSnapshot?.fetchedAt
        }
    }

    private func needsRefresh(_ feed: Feed, manual: Bool) -> Bool {
        let date = now()
        if let limitedUntil = serverRetryDates[feed], date < limitedUntil { return false }
        if manual { return true }
        if let retry = retryDates[feed] { return date >= retry }
        if failures.contains(feed) { return true }
        if feed == .community {
            return community.map { date < $0.fetchedAt || date.timeIntervalSince($0.fetchedAt) >= 300 } ?? true
        }
        return CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: fetchDate(feed), now: date)
    }

    private func loadCacheAndSchedule(forceRefresh: Bool = false) {
        refreshTimer?.invalidate()
        nextRefreshAt = nil
        guard settings.codexRadarEnabled else {
            cancelRefresh()
            snapshot = .disabled
            lastCheckedAt = nil
            community = nil
            communityMessage = nil
            return
        }
        func loaded(_ directory: URL) -> CodexRadarSnapshot {
            guard let cached = CodexRadarCache.load(from: directory) else { return .loading }
            let stale = cached.dataSource == .publicSummary
                || CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: cached.fetchedAt, now: now())
            return cached.withState(stale ? .stale : .ready, message: stale ? "缓存已过期，正在后台更新" : nil)
        }
        softwareSnapshot = loaded(cacheDirectory)
        visualSnapshot = loaded(cacheDirectory.appendingPathComponent("visual"))
        benchCache = CodexRadarCache.loadValue(CodexRadarBenchCache.self, name: "bench.json", from: cacheDirectory)
        benchCacheMessage = nil
        currentRoundCache = CodexRadarCache.loadValue(CodexRadarCurrentRoundCache.self,
            name: "four-task-v2.json", from: cacheDirectory)
        currentRound = try? currentRoundCache?.validatedRound()
        if currentRound == nil { currentRoundCache = nil }
        currentRoundMessage = nil
        failures = benchCache?.errors.isEmpty == false ? [.bench] : []
        community = CodexRadarCache.loadValue(CodexRadarCommunitySnapshot.self, name: "community.json", from: cacheDirectory)
        communityMessage = community.map {
            now().timeIntervalSince($0.fetchedAt) >= 300 || now().timeIntervalSince($0.updatedAt) > 3600
                ? "社区体感缓存已过期，正在后台更新" : nil
        } ?? nil
        news = CodexRadarCache.loadNews(from: cacheDirectory)
        newsMessage = nil
        lastCheckedAt = [currentRound?.fetchedAt, benchCache?.checkedAt, community?.fetchedAt, softwareSnapshot.fetchedAt,
                         visualSnapshot.fetchedAt, news?.fetchedAt].compactMap { $0 }.max()
        updateDisplayedSnapshot()
        if forceRefresh { refreshFromNetwork() }
        else { refreshIfNeeded() }
    }

    private func updateDisplayedSnapshot() {
        guard settings.codexRadarEnabled else { snapshot = .disabled; return }
        if selectedDimension == .comprehensive {
            if let currentRound {
                let cached = failures.contains(.currentRound)
                    || CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: currentRound.fetchedAt, now: now())
                snapshot = currentRound.snapshot(cached: cached,
                    message: currentRoundMessage ?? (cached ? "当前总榜缓存已过期，正在后台更新" : nil))
            } else {
                snapshot = .loading
                snapshot.dataSource = .publicCurrentRound
                snapshot = snapshot.withState(failures.contains(.currentRound) ? .error : .loading,
                    message: currentRoundMessage ?? "正在读取官网当前四项总榜")
            }
        } else if let benchCache, !benchCache.entries.isEmpty {
            snapshot = benchCache.snapshot(for: selectedDimension, failure: nil)
            if snapshot.state == .ready,
               CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: oldestFetchAt, now: now()) {
                snapshot = snapshot.withState(.stale, message: "雷达评分缓存已过期，正在后台更新")
            }
        } else {
            switch selectedDimension {
            case .software: snapshot = softwareSnapshot
            case .visual: snapshot = visualSnapshot
            case .comprehensive: break
            case .terminal, .science: snapshot = .loading
            }
            let failure = benchCache?.snapshot(for: selectedDimension, failure: nil).message
            if snapshot.hasData && !snapshot.models.isEmpty {
                snapshot = snapshot.withState(.stale, message: ["当前雷达分尚未获取，以下为旧基准缓存", failure].compactMap { $0 }.joined(separator: "\n"))
            } else if let benchCache {
                snapshot = benchCache.snapshot(for: selectedDimension, failure: nil)
            }
        }
        if isRefreshing && snapshot.models.isEmpty && snapshot.state != .error {
            snapshot = snapshot.withState(.loading, message: "正在读取此维度的评分")
        }
        if selectedDimension != .comprehensive, let benchCacheMessage {
            snapshot.message = [snapshot.message, benchCacheMessage].compactMap { $0 }.joined(separator: "\n")
        }
        if let authorizedSnapshot {
            snapshot.quotaRows = authorizedSnapshot.quotaRows
            snapshot.quotaUpdatedAt = authorizedSnapshot.quotaUpdatedAt
            if authorizedSnapshot.state != .ready {
                snapshot.message = [snapshot.message, authorizedSnapshot.message].compactMap { $0 }.joined(separator: "；")
            }
        }
    }

    private nonisolated static func capture<Value: Sendable>(_ action: @Sendable () async throws -> Value) async -> Result<Value, Error> {
        do { return .success(try await action()) }
        catch { return .failure(error) }
    }

    private func refreshFromNetwork(manual: Bool = false) {
        guard settings.codexRadarEnabled, !isRefreshing else { return }
        let feeds = activeFeeds.filter { needsRefresh($0, manual: manual) }
        guard !feeds.isEmpty else { scheduleNextRefresh(); return }
        refreshTimer?.invalidate()
        nextRefreshAt = nil
        isRefreshing = true
        updateDisplayedSnapshot()
        generation += 1
        let currentGeneration = generation
        let token = settings.codexRadarAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = client
        refreshTask = Task { [weak self] in
            await withTaskGroup(of: FeedResult.self) { group in
                for feed in feeds {
                    group.addTask {
                        switch feed {
                        case .currentRound: .currentRound(await Self.capture { try await client.fetchCurrentRound() })
                        case .bench: .bench(await Self.capture { try await client.fetchBench() })
                        case .community: .community(await Self.capture { try await client.fetchCommunity() })
                        case .news: .news(await Self.capture { try await client.fetchNews() })
                        case .authorized: .authorized(await Self.capture { try await client.fetch(token: token).data })
                        }
                    }
                }
                // 各来源完成即发布；旧评分源的慢请求不阻塞总榜、社区或新闻。
                for await result in group {
                    guard let self, !Task.isCancelled, currentGeneration == self.generation else { continue }
                    self.apply(result, fetchedAt: self.now())
                    self.updateDisplayedSnapshot()
                }
            }
            guard let self, !Task.isCancelled, currentGeneration == self.generation else { return }
            self.isRefreshing = false
            self.refreshTask = nil
            if !self.failures.isEmpty { self.lastManualRefreshAt = nil }
            else if manual { self.lastManualRefreshAt = self.now() }
            self.updateDisplayedSnapshot()
            self.scheduleNextRefresh()
        }
    }

    private func record(_ feed: Feed, succeeded: Bool, at date: Date, retryAfter: TimeInterval? = nil) {
        if succeeded {
            failures.remove(feed)
            retryDates.removeValue(forKey: feed)
            serverRetryDates.removeValue(forKey: feed)
        } else {
            failures.insert(feed)
            let delay = max(CodexRadarRefreshPolicy.retryInterval, retryAfter ?? 0)
            retryDates[feed] = date.addingTimeInterval(delay)
            if let retryAfter, retryAfter > 0 {
                serverRetryDates[feed] = date.addingTimeInterval(retryAfter)
            } else {
                serverRetryDates.removeValue(forKey: feed)
            }
        }
    }

    private func apply(_ result: FeedResult, fetchedAt: Date) {
        lastCheckedAt = fetchedAt
        switch result {
        case .currentRound(let result):
            do {
                let data = try result.get()
                let round = try CodexRadarCurrentRound.decode(data, fetchedAt: fetchedAt)
                currentRound = round
                currentRoundCache = .init(data: data, round: round)
                currentRoundMessage = nil
                record(.currentRound, succeeded: true, at: fetchedAt)
                do { try CodexRadarCache.saveValue(currentRoundCache!, name: "four-task-v2.json", to: cacheDirectory) }
                catch { currentRoundMessage = "当前总榜已获取，但本地缓存保存失败" }
            } catch {
                record(.currentRound, succeeded: false, at: fetchedAt, retryAfter: (error as? CodexRadarClientError)?.retryAfter)
                let retained = currentRound == nil ? "暂无当前总榜缓存" : "保留最近成功的当前总榜缓存"
                currentRoundMessage = "当前总榜未更新：\(message(error))；\(retained)；\(retryText(.currentRound))"
            }
        case .bench(let result):
            var retryAfter: TimeInterval?
            do {
                let batch = try result.get()
                retryAfter = batch.retryAfter
                benchCache = .merging(batch.decode(fetchedAt: fetchedAt), previous: benchCache, checkedAt: fetchedAt)
            } catch {
                retryAfter = (error as? CodexRadarClientError)?.retryAfter
                benchCache = .init(entries: benchCache?.entries ?? [], checkedAt: fetchedAt,
                                   errors: ["旧基准评分源": message(error)])
            }
            record(.bench, succeeded: benchCache?.errors.isEmpty == true, at: fetchedAt, retryAfter: retryAfter)
            benchCacheMessage = failures.contains(.bench) ? retryText(.bench) : nil
            do { try CodexRadarCache.saveValue(benchCache!, name: "bench.json", to: cacheDirectory) }
            catch {
                benchCacheMessage = [benchCacheMessage, "旧基准评分缓存保存失败"].compactMap { $0 }.joined(separator: "；")
            }
        case .community(let result):
            do {
                community = try CodexRadarCommunitySnapshot.decode(result.get(), fetchedAt: fetchedAt)
                let stale = fetchedAt.timeIntervalSince(community!.updatedAt) > 3600
                communityMessage = stale ? "社区体感接口返回旧数据，以下为过期的 24 小时投票快照" : nil
                record(.community, succeeded: !stale, at: fetchedAt)
                do { try CodexRadarCache.saveValue(community!, name: "community.json", to: cacheDirectory) }
                catch { communityMessage = "社区体感分已获取，但本地缓存保存失败" }
            } catch {
                record(.community, succeeded: false, at: fetchedAt, retryAfter: (error as? CodexRadarClientError)?.retryAfter)
                communityMessage = "社区体感分未更新：\(message(error))；\(retryText(.community))"
            }
        case .news(let result):
            do {
                news = try CodexRadarNewsParser.decode(result.get(), fetchedAt: fetchedAt)
                newsMessage = nil
                record(.news, succeeded: true, at: fetchedAt)
                do { try CodexRadarCache.saveNews(news!, to: cacheDirectory) }
                catch { newsMessage = "新闻已获取，但本地缓存保存失败" }
            } catch {
                record(.news, succeeded: false, at: fetchedAt, retryAfter: (error as? CodexRadarClientError)?.retryAfter)
                newsMessage = "新闻暂未更新：\(message(error))；\(retryText(.news))"
            }
        case .authorized(let result):
            let applied = applyScores(result, source: .authorizedAPI, previous: authorizedSnapshot ?? .loading,
                                      directory: cacheDirectory.appendingPathComponent("authorized"), fetchedAt: fetchedAt)
            authorizedSnapshot = applied.snapshot
            let retryAfter: TimeInterval?
            if case .failure(let error) = result { retryAfter = (error as? CodexRadarClientError)?.retryAfter }
            else { retryAfter = nil }
            record(.authorized, succeeded: applied.succeeded, at: fetchedAt, retryAfter: retryAfter)
        }
    }

    private func message(_ error: any Error) -> String {
        ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription).redactedForDisplay
    }

    private func retryText(_ feed: Feed) -> String {
        if let until = serverRetryDates[feed], until > now() {
            return "上游要求等待至 \(until.formatted(date: .omitted, time: .standard)) 后重试"
        }
        return "5 分钟后自动重试，可手动重试"
    }

    private func applyScores(_ result: Result<Data, Error>, source: CodexRadarDataSource,
                             previous: CodexRadarSnapshot, directory: URL, fetchedAt: Date)
        -> (snapshot: CodexRadarSnapshot, succeeded: Bool) {
        do {
            let data = try result.get()
            var next = try CodexRadarSnapshot.decode(data: data, fetchedAt: fetchedAt, source: source)
            do { try CodexRadarCache.save(data: data, fetchedAt: fetchedAt, source: source, to: directory) }
            catch { next = next.withState(.ready, message: "数据已获取，但本地缓存保存失败") }
            return (next, true)
        } catch {
            let message = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription).redactedForDisplay
            var failed = previous.withState(previous.hasData ? .stale : .error,
                    message: "\(message)；5 分钟后自动重试，可手动重试")
            if !previous.hasData { failed.dataSource = source }
            return (failed, false)
        }
    }

    private func observeSettings() {
        settings.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.settingsDidChange() }
            }
            .store(in: &cancellables)
    }

    private func settingsDidChange() {
        let enabled = settings.codexRadarEnabled
        let token = settings.codexRadarAPIToken
        guard enabled != observedEnabled || token != observedToken else { return }
        observedEnabled = enabled
        observedToken = token
        cancelRefresh()
        authorizedSnapshot = nil
        retryDates.removeAll()
        serverRetryDates.removeAll()
        failures.removeAll()
        lastManualRefreshAt = nil
        refreshTimer?.invalidate()
        nextRefreshAt = nil
        if !enabled {
            snapshot = .disabled
            lastCheckedAt = nil
            community = nil
            communityMessage = nil
        }
        settingsTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.loadCacheAndSchedule(forceRefresh: true) }
        }
        timer.tolerance = 0.15
        settingsTimer = timer
    }

    private func scheduleNextRefresh() {
        guard settings.codexRadarEnabled, !isRefreshing else { return }
        refreshTimer?.invalidate()
        let date = now()
        let scheduled = activeFeeds.map { feed -> Date in
            if let retry = retryDates[feed] { return max(date, retry) }
            if let limited = serverRetryDates[feed], limited > date { return limited }
            if needsRefresh(feed, manual: false) { return date }
            if feed == .community { return community?.fetchedAt.addingTimeInterval(300) ?? date }
            return CodexRadarRefreshPolicy.nextRefresh(after: date, lastFetchAt: fetchDate(feed))
        }.min() ?? date.addingTimeInterval(300)
        nextRefreshAt = scheduled
        let interval = max(1, scheduled.timeIntervalSince(date))
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshIfNeeded() }
        }
        timer.tolerance = min(30, interval * 0.1)
        refreshTimer = timer
    }

    private func cancelRefresh() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }
}

private enum CodexRadarCache {
    static func loadValue<Value: Decodable>(_ type: Value.Type, name: String, from directory: URL) -> Value? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func saveValue<Value: Encodable>(_ value: Value, name: String, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, S_IRWXU)
        let url = directory.appendingPathComponent(name)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        chmod(url.path, S_IRUSR | S_IWUSR)
    }
    struct Metadata: Codable {
        let fetchedAt: Date
        let source: CodexRadarDataSource
    }

    static func defaultDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return root.appendingPathComponent("codex监测/CodexRadar", isDirectory: true)
    }

    static func load(from directory: URL) -> CodexRadarSnapshot? {
        let dataURL = directory.appendingPathComponent("current.json")
        let metadataURL = directory.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: dataURL),
              let metadataData = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: metadataData) else { return nil }
        return try? CodexRadarSnapshot.decode(data: data, fetchedAt: metadata.fetchedAt, source: metadata.source)
    }

    static func loadNews(from directory: URL) -> CodexRadarNewsSnapshot? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("news.json")) else { return nil }
        return try? JSONDecoder().decode(CodexRadarNewsSnapshot.self, from: data)
    }

    static func saveNews(_ news: CodexRadarNewsSnapshot, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, S_IRWXU)
        let url = directory.appendingPathComponent("news.json")
        try JSONEncoder().encode(news).write(to: url, options: .atomic)
        chmod(url.path, S_IRUSR | S_IWUSR)
    }

    static func save(data: Data, fetchedAt: Date, source: CodexRadarDataSource, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, S_IRWXU)
        let dataURL = directory.appendingPathComponent("current.json")
        let metadataURL = directory.appendingPathComponent("metadata.json")
        try data.write(to: dataURL, options: .atomic)
        try JSONEncoder().encode(Metadata(fetchedAt: fetchedAt, source: source)).write(to: metadataURL, options: .atomic)
        chmod(dataURL.path, S_IRUSR | S_IWUSR)
        chmod(metadataURL.path, S_IRUSR | S_IWUSR)
    }
}
