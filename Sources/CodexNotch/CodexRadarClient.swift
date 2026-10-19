import Foundation

struct CodexRadarClient: Sendable {
    // The website's live software-engineering scores replaced the static current.json feed.
    static let publicURL = URL(string: "https://codexradar.com/api/intelligence-efficiency-metrics")!
    static let authorizedURL = URL(string: "https://codexradar.com/api/v1/current")!
    static let visualURL = URL(string: "https://codexradar.com/api/visual-spatial-reasoning")!
    static let newsURL = URL(string: "https://codexradar.com/")!
    static let bindingURL = URL(string: "https://codexradar.com/data/radar-bench-binding.json")!
    static let benchURL = URL(string: "https://codexradar.com/api/radar-bench-score")!
    static let communityURL = URL(string: "https://codexradar.com/api/model-ratings")!

    let publicEndpoint: URL
    let authorizedEndpoint: URL
    let timeout: TimeInterval
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        publicEndpoint: URL = Self.publicURL,
        authorizedEndpoint: URL = Self.authorizedURL,
        timeout: TimeInterval = 15,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = Self.send
    ) {
        self.publicEndpoint = publicEndpoint
        self.authorizedEndpoint = authorizedEndpoint
        self.timeout = timeout
        self.transport = transport
    }

    func fetch(token: String?, forceRefresh: Bool = false) async throws -> (data: Data, source: CodexRadarDataSource) {
        let token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let token, !token.isEmpty {
            return (try await request(url: authorizedEndpoint, token: token), .authorizedAPI)
        }
        var components = URLComponents(url: publicEndpoint, resolvingAgainstBaseURL: false)!
        if forceRefresh { components.queryItems = [URLQueryItem(name: "refresh", value: "1")] }
        return (try await request(url: components.url!, token: nil), .publicMetrics)
    }

    func fetchVisual(forceRefresh: Bool = false) async throws -> Data {
        let url = forceRefresh ? URL(string: Self.visualURL.absoluteString + "?refresh=1")! : Self.visualURL
        return try await request(url: url, token: nil)
    }

    func fetchNews() async throws -> Data {
        try await request(url: Self.newsURL, token: nil)
    }

    func fetchCommunity() async throws -> Data {
        try await request(url: Self.communityURL, token: nil)
    }

    func fetchBench() async throws -> CodexRadarBenchBatch {
        let binding = try JSONDecoder().decode(CodexRadarBenchBinding.self,
                                              from: await request(url: Self.bindingURL, token: nil))
        try binding.validate()
        var results: [CodexRadarSelection: Result<Data, Error>] = [:]
        await withTaskGroup(of: (CodexRadarSelection, Result<Data, Error>).self) { group in
            var iterator = binding.model_efforts.makeIterator()
            func add(_ selection: CodexRadarSelection) {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        var url = URLComponents(url: Self.benchURL, resolvingAgainstBaseURL: false)!
                        url.queryItems = [.init(name: "model", value: selection.model),
                                          .init(name: "effort", value: selection.effort), .init(name: "view", value: "summary")]
                        return (selection, .success(try await request(url: url.url!, token: nil, timeoutOverride: 40)))
                    } catch { return (selection, .failure(error)) }
                }
            }
            for _ in 0..<3 { if let selection = iterator.next() { add(selection) } }
            for await (selection, result) in group {
                results[selection] = result
                if !Task.isCancelled, let next = iterator.next() { add(next) }
            }
        }
        try Task.checkCancellation()
        return CodexRadarBenchBatch(binding: binding, results: results)
    }

    private func request(url: URL, token: String?, timeoutOverride: TimeInterval? = nil) async throws -> Data {
        guard Self.isAllowed(url, authorized: token != nil) else {
            throw CodexRadarClientError.disallowedURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutOverride ?? timeout)
        request.httpShouldHandleCookies = false
        request.setValue(url.path == "/" ? "text/html" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-monitor/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await transport(request)
        guard let response = response as? HTTPURLResponse else {
            throw CodexRadarClientError.invalidResponse
        }
        guard response.statusCode == 200 else {
            throw CodexRadarClientError.httpStatus(response.statusCode)
        }
        if token == nil, let cacheStatus = response.value(forHTTPHeaderField: "X-Codex-Cache")?.uppercased(),
           cacheStatus.hasPrefix("STALE") || cacheStatus == "ERROR" {
            throw CodexRadarClientError.staleResponse
        }
        guard !data.isEmpty else { throw CodexRadarClientError.emptyResponse }
        return data
    }

    static func isAllowed(_ url: URL, authorized: Bool) -> Bool {
        let base = url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "codexradar.com"
            && (url.port == nil || url.port == 443)
            && url.user == nil
            && url.password == nil
            && url.fragment == nil
        guard base else { return false }
        if authorized { return url.path == "/api/v1/current" && url.query == nil }
        if url.path == Self.benchURL.path {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard items.count == 3, Set(items.map(\.name)) == ["model", "effort", "view"],
                  items.first(where: { $0.name == "view" })?.value == "summary",
                  let model = items.first(where: { $0.name == "model" })?.value,
                  let effort = items.first(where: { $0.name == "effort" })?.value else { return false }
            return CodexRadarSelection(model: model, effort: effort).isSupported
        }
        if [Self.bindingURL.path, Self.communityURL.path, "/"].contains(url.path) { return url.query == nil }
        return [Self.publicURL.path, Self.visualURL.path].contains(url.path)
            && (url.query == nil || url.query == "refresh=1")
    }

    private static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }
}

enum CodexRadarClientError: LocalizedError {
    case disallowedURL
    case invalidResponse
    case httpStatus(Int)
    case emptyResponse
    case staleResponse

    var errorDescription: String? {
        switch self {
        case .disallowedURL: "CodexRadar 地址不受信任"
        case .invalidResponse: "CodexRadar 返回了无效响应"
        case .httpStatus(let status): status == 401 ? "CodexRadar Token 无效或未授权" : "CodexRadar HTTP \(status)"
        case .emptyResponse: "CodexRadar 返回空数据"
        case .staleResponse: "CodexRadar 暂时只返回过期缓存"
        }
    }
}
