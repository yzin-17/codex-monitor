import Foundation

public enum LedgerMath {
    public static func merge(_ files: [Session]) -> [Session] {
        var results: [Session] = []
        for (_, versions) in Dictionary(grouping: files, by: \.id) {
            let sorted = versions.sorted {
                if $0.samples.count != $1.samples.count { return $0.samples.count > $1.samples.count }
                return ($0.files.first ?? "") < ($1.files.first ?? "")
            }
            guard var session = sorted.first else { continue }
            session.files = Array(Set(versions.flatMap(\.files))).sorted()
            var seen: Set<String> = []; var evidenceSeen: Set<String> = []
            session.samples = versions.flatMap(\.samples).sorted {
                if $0.sourceOffset != $1.sourceOffset { return $0.sourceOffset < $1.sourceOffset }
                return $0.id < $1.id
            }.filter { seen.insert($0.id).inserted }
            session.evidence = versions.flatMap(\.evidence).filter { evidenceSeen.insert($0.id).inserted }
            session.issues = Array(Set(versions.flatMap(\.issues))).sorted()
            session.lastActivity = versions.compactMap(\.lastActivity).max()
            // 同 ID 的重叠快照不能把每个增量再加一遍。相同累计值的有效请求只保留一次。
            var cumulativeSeen = Set<TokensKey>()
            session.samples = session.samples.filter {
                guard let cumulative = $0.cumulative else { return true }
                return cumulativeSeen.insert(TokensKey(cumulative)).inserted
            }
            results.append(session)
        }
        let ancestors = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        for index in results.indices {
            var current = results[index].forkedFromID
            var seen: Set<String> = [results[index].id]; var inherited: Set<String> = []
            while let id = current, let ancestor = ancestors[id], seen.insert(id).inserted {
                inherited.formUnion(ancestor.samples.map(\.id)); current = ancestor.forkedFromID
            }
            if let parent = results[index].forkedFromID, ancestors[parent] == nil {
                results[index].issues.append("fork 原对话不可见；可能包含无法确认的继承历史")
            }
            if !inherited.isEmpty {
                results[index].samples.removeAll { inherited.contains($0.id) }
                results[index].issues.append("已排除与可见 fork 祖先完全相同的历史计数事件")
            }
        }
        return results.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }
    private struct TokensKey: Hashable {
        let input, cached, output, reasoning: Int64
        init(_ t: Tokens) { input = t.input; cached = t.cached; output = t.output; reasoning = t.reasoning }
    }
    public static func tasks(_ sessions: [Session]) -> [TaskUsage] {
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        func root(of session: Session) -> String {
            var current = session.id; var path: [String] = []; var positions: [String:Int] = [:]
            while let parent = byID[current]?.parentID, byID[parent] != nil {
                if let position = positions[current] { return path[position...].sorted().first ?? session.id }
                positions[current] = path.count; path.append(current); current = parent
            }
            return current
        }
        let groups = Dictionary(grouping: sessions, by: root)
        return groups.compactMap { id, rows in
            guard let parent = byID[id] else { return nil }
            return TaskUsage(root: parent, descendants: rows.filter { $0.id != id }.sorted { $0.id < $1.id })
        }.sorted { $0.total.total > $1.total.total }
    }
    public static func usage(_ sessions: [Session], since: Date? = nil, until: Date = .distantFuture) -> Tokens {
        samples(sessions, since: since, until: until).reduce(.zero) { $0 + $1.tokens }
    }
    public static func samples(_ sessions: [Session], since: Date? = nil, until: Date = .distantFuture) -> [UsageSample] {
        sessions.flatMap(\.samples).filter { sample in
            guard let since else { return true }
            guard let date = sample.date else { return false }
            return date >= since && date < until
        }
    }
    public static func models(_ sessions: [Session], since: Date? = nil, until: Date = .distantFuture) -> [ModelUsage] {
        Dictionary(grouping: samples(sessions, since: since, until: until), by: \.model).map { model, rows in
            ModelUsage(model: model, tokens: rows.reduce(.zero) { $0 + $1.tokens })
        }.sorted { $0.tokens.total > $1.tokens.total }
    }
    public static func skillRows(_ skills: [Skill], sessions: [Session], since: Date?) -> [SkillRow] {
        let evidence = sessions.flatMap(\.evidence).filter { evidence in
            guard let since else { return true }
            return evidence.date.map { $0 >= since } ?? false
        }
        let names = Dictionary(grouping: skills, by: \.name)
        return skills.map { skill in
            let matches = evidence.filter { evidence in
                if let path = evidence.path {
                    return Paths.url(path).resolvingSymlinksInPath().path == Paths.url(skill.path).resolvingSymlinksInPath().path
                }
                guard evidence.name == skill.name else { return false }
                let matching = (names[skill.name] ?? []).filter { candidate in
                    guard let cwd = candidate.cwd else { return true }
                    return evidence.cwd == cwd
                }
                return matching.count == 1 && matching[0].path == skill.path
            }
            return SkillRow(skill: skill, evidence: matches)
        }.sorted {
            if $0.evidence.count != $1.evidence.count { return $0.evidence.count > $1.evidence.count }
            return $0.skill.name < $1.skill.name
        }
    }
}

public struct ModelPrice: Codable, Sendable, Identifiable {
    public var model: String
    public var inputPerMillion: Double
    public var cachedPerMillion: Double
    public var outputPerMillion: Double
    public var maxInput: Int64?
    public var id: String { model }
    public init(model: String, inputPerMillion: Double, cachedPerMillion: Double, outputPerMillion: Double, maxInput: Int64? = nil) {
        self.model = model; self.inputPerMillion = inputPerMillion; self.cachedPerMillion = cachedPerMillion
        self.outputPerMillion = outputPerMillion; self.maxInput = maxInput
    }
}
public struct PriceBook: Codable, Sendable {
    public var currency: String
    public var note: String
    public var models: [ModelPrice]
    public init(currency: String = "USD", note: String = "用户提供的单档参考费率，不是订阅账单", models: [ModelPrice] = []) {
        self.currency = currency; self.note = note; self.models = models
    }
    public static func decode(_ data: Data) throws -> PriceBook {
        guard data.count <= 1024 * 1024 else { throw LedgerError.invalidPrices }
        let book = try JSONDecoder().decode(PriceBook.self, from: data)
        guard Set(book.models.map(\.model)).count == book.models.count,
              book.models.allSatisfy({ !$0.model.isEmpty && [$0.inputPerMillion, $0.cachedPerMillion, $0.outputPerMillion].allSatisfy { $0.isFinite && $0 >= 0 }
                  && ($0.maxInput.map { $0 > 0 } ?? true) }) else { throw LedgerError.invalidPrices }
        return book
    }
    public func estimate(_ samples: [UsageSample]) -> (amount: Double, excludedTokens: Int64) {
        var amount: Double = 0; var excluded: Int64 = 0
        for s in samples {
            guard !s.isBaseline, let price = models.first(where: { $0.model == s.model }) else {
                excluded = Tokens.safeAdd(excluded, s.tokens.total); continue
            }
            if let ceiling = price.maxInput {
                guard let lastInput = s.lastInput, lastInput <= ceiling else {
                    excluded = Tokens.safeAdd(excluded, s.tokens.total); continue
                }
            }
            amount += (Double(s.tokens.uncached) * price.inputPerMillion + Double(s.tokens.cached) * price.cachedPerMillion + Double(s.tokens.output) * price.outputPerMillion) / 1_000_000
        }
        return (amount, excluded)
    }
}
