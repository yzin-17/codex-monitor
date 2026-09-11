import Combine
import Foundation

final class PublicInsightsClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func fetch(_ source: PublicInsightSource) async throws -> PublicInsightSnapshot {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        func load(_ url: URL) async throws -> Data {
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("CodexMonitor/0.4", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw PublicInsightError.invalidResponse }
            if (300..<400).contains(http.statusCode) { throw PublicInsightError.redirect }
            guard http.statusCode == 200 else { throw PublicInsightError.http(http.statusCode) }
            guard response.expectedContentLength <= 2 * 1024 * 1024 else { throw PublicInsightError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                if data.count % 4096 == 0 { try Task.checkCancellation() }
                guard data.count < 2 * 1024 * 1024 else { throw PublicInsightError.tooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return data
        }

        if source == .openAIStatus {
            // 与 CodexBar 一致：优先 incident.io 原生结构，以获得 APIs / ChatGPT / Codex 等真实分组。
            // 原生结构不可用时才退回经典 Statuspage summary.json。
            do {
                let incident = try await load(PublicInsightSource.openAIIncidentEndpoint)
                let overlay = try? await load(PublicInsightSource.openAIStatusEndpoint)
                return try PublicInsightParser.parseOpenAIIncident(
                    incident,
                    statusData: overlay,
                    fetchedAt: Date()
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
            }
        }

        let data = try await load(source.endpoint)
        return try PublicInsightParser.parse(data, source: source)
    }
}

@MainActor
final class PublicInsightsStore: ObservableObject {
    typealias Fetcher = @Sendable (PublicInsightSource) async throws -> PublicInsightSnapshot

    @Published private(set) var enabled: Set<PublicInsightSource> = []
    @Published private(set) var snapshots: [PublicInsightSource: PublicInsightSnapshot] = [:]
    @Published private(set) var errors: [PublicInsightSource: String] = [:]
    @Published private(set) var refreshing: Set<PublicInsightSource> = []

    private let defaults: UserDefaults
    private let fetcher: Fetcher
    private var tasks: [PublicInsightSource: Task<Void, Never>] = [:]
    private var generations: [PublicInsightSource: UUID] = [:]
    private var timer: Timer?
    private let automatic: Bool

    init(defaults: UserDefaults = .standard, automatic: Bool = true, fetcher: Fetcher? = nil) {
        self.defaults = defaults
        self.automatic = automatic
        self.fetcher = fetcher ?? { try await PublicInsightsClient().fetch($0) }

        if defaults.object(forKey: "publicInsights.enabled.v1") == nil {
            // 服务状态是性能页的基础诊断信息，默认开启；社区预测仍保持用户显式启用。
            enabled = [.openAIStatus]
            defaults.set([PublicInsightSource.openAIStatus.rawValue], forKey: "publicInsights.enabled.v1")
        } else {
            enabled = Set((defaults.stringArray(forKey: "publicInsights.enabled.v1") ?? [])
                .compactMap(PublicInsightSource.init(rawValue:)))
        }

        if let data = defaults.data(forKey: "publicInsights.cache.v1"),
           data.count <= 512 * 1024,
           let cache = try? JSONDecoder().decode([PublicInsightSnapshot].self, from: data) {
            for item in cache { snapshots[item.source] = item }
        }

        // 只有已启用的公共来源才轮询。预览和测试不启动网络。
        if automatic { schedule() }
    }

    func setEnabled(_ source: PublicInsightSource, _ value: Bool) {
        if value {
            enabled.insert(source)
        } else {
            enabled.remove(source)
            generations[source] = UUID()
            tasks.removeValue(forKey: source)?.cancel()
            refreshing.remove(source)
        }
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: "publicInsights.enabled.v1")
        if value { refresh(source) }
        schedule()
    }

    func refresh(_ source: PublicInsightSource) {
        guard enabled.contains(source), tasks[source] == nil else { return }
        let generation = UUID()
        generations[source] = generation
        refreshing.insert(source)
        tasks[source] = Task { [weak self, fetcher] in
            let result: Result<PublicInsightSnapshot, Error>
            do { result = .success(try await fetcher(source)) }
            catch { result = .failure(error) }

            guard let self,
                  !Task.isCancelled,
                  self.enabled.contains(source),
                  self.generations[source] == generation else { return }
            self.tasks[source] = nil
            self.refreshing.remove(source)
            switch result {
            case .success(let value):
                guard value.source == source else {
                    self.errors[source] = PublicInsightError.invalidResponse.localizedDescription
                    return
                }
                self.snapshots[source] = value
                self.errors[source] = nil
                if let data = try? JSONEncoder().encode(Array(self.snapshots.values)), data.count <= 512 * 1024 {
                    self.defaults.set(data, forKey: "publicInsights.cache.v1")
                }
            case .failure(let error):
                self.errors[source] = (error as? PublicInsightError)?.localizedDescription
                    ?? "连接失败，保留上次数据；不会将失败显示为正常。"
            }
        }
    }

    func refreshPredictions() {
        for source in [PublicInsightSource.observatory, .willReset] { refresh(source) }
    }

    func refreshIfNeeded() {
        let now = Date()
        for source in enabled where snapshots[source].map({
            now.timeIntervalSince($0.fetchedAt) >= source.refreshInterval
        }) ?? true {
            refresh(source)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        refreshing.removeAll()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard automatic, !enabled.isEmpty else { return }
        refreshIfNeeded()
        let interval = enabled.map(\.refreshInterval).min() ?? 1800
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfNeeded() }
        }
    }

    var forecastAlert: (source: PublicInsightSource, probability: Double)? {
        let now = Date()
        return [PublicInsightSource.observatory, .willReset].compactMap { source -> (PublicInsightSource, Double)? in
            guard enabled.contains(source),
                  errors[source] == nil,
                  let snapshot = snapshots[source],
                  !snapshot.isStale(now: now),
                  let highest = snapshot.probabilities.values.max(),
                  highest > 70 else { return nil }
            return (source, highest)
        }
        .max { $0.1 < $1.1 }
    }

    func installPreview(_ values: [PublicInsightSnapshot]) {
        guard !automatic else { return }
        enabled = Set(values.map(\.source))
        snapshots = Dictionary(uniqueKeysWithValues: values.map { ($0.source, $0) })
    }
}
