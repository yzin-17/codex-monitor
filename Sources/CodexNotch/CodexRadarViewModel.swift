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
    private var benchDue: Bool {
        benchCache == nil || !(benchCache?.errors.isEmpty ?? true)
            || CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: benchCache?.entries.map(\.fetchedAt).min(), now: now())
    }
    private var refreshTimer: Timer?
    private var settingsTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var generation = 0
    private var observedEnabled: Bool
    private var observedToken: String
    private var lastManualRefreshAt: Date?
    private var retryAt: Date?

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
        if let retryAt, now() < retryAt {
            scheduleNextRefresh()
            return
        }
        if retryAt != nil || benchDue || news == nil || community == nil
            || community.map({ now().timeIntervalSince($0.fetchedAt) >= 300 || now() < $0.fetchedAt }) == true
            || (!settings.codexRadarAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && authorizedSnapshot == nil)
            || CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: oldestFetchAt, now: now()) {
            refreshFromNetwork()
        } else {
            scheduleNextRefresh()
        }
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
        community = CodexRadarCache.loadValue(CodexRadarCommunitySnapshot.self, name: "community.json", from: cacheDirectory)
        communityMessage = community.map {
            now().timeIntervalSince($0.fetchedAt) >= 300 || now().timeIntervalSince($0.updatedAt) > 3600
                ? "社区体感缓存已过期，正在后台更新" : nil
        } ?? nil
        news = CodexRadarCache.loadNews(from: cacheDirectory)
        newsMessage = nil
        lastCheckedAt = [benchCache?.checkedAt, community?.fetchedAt, softwareSnapshot.fetchedAt,
                         visualSnapshot.fetchedAt, news?.fetchedAt].compactMap { $0 }.max()
        updateDisplayedSnapshot()
        if forceRefresh { refreshFromNetwork() }
        else { refreshIfNeeded() }
    }

    private func updateDisplayedSnapshot() {
        guard settings.codexRadarEnabled else { snapshot = .disabled; return }
        if let benchCache, !benchCache.entries.isEmpty {
            snapshot = benchCache.snapshot(for: selectedDimension, failure: nil)
            if snapshot.state == .ready,
               CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: oldestFetchAt, now: now()) {
                snapshot = snapshot.withState(.stale, message: "雷达评分缓存已过期，正在后台更新")
            }
        } else {
            switch selectedDimension {
            case .software: snapshot = softwareSnapshot
            case .visual: snapshot = visualSnapshot
            case .comprehensive: snapshot = .comprehensive(software: softwareSnapshot, visual: visualSnapshot)
            case .terminal, .science: snapshot = .loading
            }
            let failure = benchCache?.snapshot(for: selectedDimension, failure: nil).message
            if snapshot.hasData && !snapshot.models.isEmpty {
                snapshot = snapshot.withState(.stale, message: ["当前雷达分尚未获取，以下为旧基准缓存", failure].compactMap { $0 }.joined(separator: "\n"))
            } else if let benchCache {
                snapshot = benchCache.snapshot(for: selectedDimension, failure: nil)
            }
        }
        if isRefreshing && snapshot.models.isEmpty {
            snapshot = snapshot.withState(.loading, message: "正在读取此维度的评分")
        }
        if let benchCacheMessage {
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
        refreshTimer?.invalidate()
        nextRefreshAt = nil
        isRefreshing = true
        updateDisplayedSnapshot()
        generation += 1
        let currentGeneration = generation
        let token = settings.codexRadarAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = client
        let readBench = manual || benchDue
        let readCommunity = manual || community == nil || communityMessage != nil
            || community.map { now().timeIntervalSince($0.fetchedAt) >= 300 || now() < $0.fetchedAt } == true
        let readNews = manual || newsMessage != nil
            || CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: news?.fetchedAt, now: now())
        let readAuthorized = !token.isEmpty && (manual || authorizedSnapshot?.state != .ready
            || CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: authorizedSnapshot?.fetchedAt, now: now()))
        refreshTask = Task { [weak self] in
            async let bench: Result<CodexRadarBenchBatch, Error>? = readBench ? Self.capture { try await client.fetchBench() } : nil
            async let communityResult: Result<Data, Error>? = readCommunity ? Self.capture { try await client.fetchCommunity() } : nil
            async let newsResult: Result<Data, Error>? = readNews ? Self.capture { try await client.fetchNews() } : nil
            async let authorized: Result<Data, Error>? = readAuthorized ? Self.capture { try await client.fetch(token: token).data } : nil
            let results = await (bench, communityResult, newsResult, authorized)
            guard let self, !Task.isCancelled, currentGeneration == self.generation else { return }
            let fetchedAt = self.now()
            self.lastCheckedAt = fetchedAt
            if let result = results.0 {
                do {
                    let read = try result.get().decode(fetchedAt: fetchedAt)
                    self.benchCache = .merging(read, previous: self.benchCache, checkedAt: fetchedAt)
                } catch {
                    let message = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription).redactedForDisplay
                    self.benchCache = .init(entries: self.benchCache?.entries ?? [], checkedAt: fetchedAt,
                                            errors: ["雷达接口": message])
                }
                self.benchCacheMessage = nil
                do { try CodexRadarCache.saveValue(self.benchCache!, name: "bench.json", to: self.cacheDirectory) }
                catch { self.benchCacheMessage = "评分已获取，但本地缓存保存失败" }
            }
            if let result = results.1 {
                do {
                    self.community = try CodexRadarCommunitySnapshot.decode(result.get(), fetchedAt: fetchedAt)
                    self.communityMessage = fetchedAt.timeIntervalSince(self.community!.updatedAt) > 3600
                        ? "社区体感接口返回旧数据，以下为过期的 24 小时投票快照" : nil
                    do { try CodexRadarCache.saveValue(self.community!, name: "community.json", to: self.cacheDirectory) }
                    catch { self.communityMessage = "社区体感分已获取，但本地缓存保存失败" }
                } catch {
                    let message = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription).redactedForDisplay
                    self.communityMessage = "社区体感分未更新：\(message)；5 分钟后自动重试，可手动重试"
                }
            }
            var failed = !(self.benchCache?.errors.isEmpty ?? true) || self.communityMessage != nil
            if let result = results.3 {
                let authorizedResult = self.applyScores(result, source: .authorizedAPI, previous: self.authorizedSnapshot ?? .loading,
                                                         directory: self.cacheDirectory.appendingPathComponent("authorized"), fetchedAt: fetchedAt)
                self.authorizedSnapshot = authorizedResult.snapshot
                failed = failed || !authorizedResult.succeeded
            }
            if let result = results.2 { do {
                self.news = try CodexRadarNewsParser.decode(result.get(), fetchedAt: fetchedAt)
                self.newsMessage = nil
                do { try CodexRadarCache.saveNews(self.news!, to: self.cacheDirectory) }
                catch { self.newsMessage = "新闻已获取，但本地缓存保存失败" }
            } catch {
                failed = true
                let message = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription).redactedForDisplay
                self.newsMessage = "新闻暂未更新：\(message)；5 分钟后自动重试，可手动重试"
            } }
            failed = failed || self.newsMessage != nil
            self.isRefreshing = false
            self.refreshTask = nil
            self.retryAt = failed ? fetchedAt.addingTimeInterval(CodexRadarRefreshPolicy.retryInterval) : nil
            if failed { self.lastManualRefreshAt = nil }
            else if manual { self.lastManualRefreshAt = fetchedAt }
            self.updateDisplayedSnapshot()
            self.scheduleNextRefresh()
        }
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
        retryAt = nil
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
        let next = CodexRadarRefreshPolicy.nextRefresh(after: date, lastFetchAt: oldestFetchAt, retryAt: retryAt)
        let communityNext = community?.fetchedAt.addingTimeInterval(300) ?? date
        let scheduled = retryAt == nil ? min(next, communityNext) : next
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
