import Foundation
import CoreFoundation

struct CodexAccount: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var label = ""
    var workspaceID = ""
    var enabled = true
    var revision = UUID()
    var verifiedAt: Date?
    var hudID: String { "codex-account:\(id.uuidString)" }
}
struct AccountQuota: Equatable, Sendable, Identifiable {
    var id: String
    var label: String
    var usedPercent: Double
    var resetsAt: Date?
    var durationSeconds: Double?
    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}
struct CodexAccountUsage: Equatable, Sendable {
    var quotas: [AccountQuota] = []
    var plan: String?
    var credits: String?
    var capturedAt = Date()
}
enum CodexAccountError: Error, LocalizedError, Sendable, Equatable {
    case missingCredential, invalidCredential, invalidResponse, tooLarge, http(Int), redirect, keychain, accountMismatch, superseded
    var errorDescription: String? {
        switch self {
        case .missingCredential: "未配置凭据，或钥匙串当前不可读；请在设置中重新导入或保存。"
        case .invalidCredential: "需要 Codex OAuth Access Token；不接受 API Key、Cookie 或完整请求头。"
        case .invalidResponse: "Codex 返回了无法识别的额度数据；未将此结果视为验证成功。"
        case .tooLarge: "文件或响应超过读取上限。"
        case .http(let code): code == 401 || code == 403 ? "HTTP \(code)：凭据过期或无读取权限，请在 Codex 重新登录后导入。" : "Codex 验证失败（HTTP \(code)）。"
        case .redirect: "为保护凭据，已拒绝 HTTP 重定向。"
        case .keychain: "钥匙串操作失败，未保存账户变更。"
        case .accountMismatch: "返回的工作区与所选 Account ID 不一致，结果未保存。"
        case .superseded: "账户已被修改或验证已取消，请重新操作。"
        }
    }
}

/// 一次性读取用户在文件选择器中明确选择的 auth.json。
/// 不自动发现登录文件，不保留 ID/Refresh Token，不改写源文件。
struct CodexCredentialImport: Sendable {
    let accessToken: String
    let workspaceID: String
    static let maximumBytes = 256 * 1024
    static func parse(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw CodexAccountError.tooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else { throw CodexAccountError.invalidCredential }
        if let mode = root["auth_mode"] as? String, mode != "chatgpt" && mode != "chatgptAuthTokens" { throw CodexAccountError.invalidCredential }
        let account = tokens["account_id"] as? String ?? ""
        try validateToken(token)
        try validateWorkspace(account)
        return .init(accessToken: token.trimmingCharacters(in: .whitespacesAndNewlines), workspaceID: account)
    }
    static func validateToken(_ token: String) throws {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw CodexAccountError.missingCredential }
        guard value.utf8.count <= 16384, !value.hasPrefix("sk-"),
              value.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }),
              !value.contains(where: { ";{}[]".contains($0) }) else { throw CodexAccountError.invalidCredential }
    }
    static func validateWorkspace(_ value: String) throws {
        guard value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }) else { throw CodexAccountError.invalidCredential }
    }
}

enum CodexAccountUsageParser {
    static let maximumBytes = 1_048_576
    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        guard let s = value as? String, let n = Double(s), n.isFinite else { return nil }
        return n
    }
    static func parse(_ data: Data, workspaceID: String = "", now: Date = Date()) throws -> CodexAccountUsage {
        guard data.count <= maximumBytes else { throw CodexAccountError.tooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CodexAccountError.invalidResponse }
        if !workspaceID.isEmpty, let returned = root["account_id"] as? String ?? root["chatgpt_account_id"] as? String,
           returned != workspaceID { throw CodexAccountError.accountMismatch }
        var result = CodexAccountUsage(capturedAt: now)
        func windows(_ limits: [String: Any], prefix: String = "", title: String = "") -> [AccountQuota] {
            [("primary_window", "5h"), ("secondary_window", "7d")].compactMap { key, fallback in
                guard let item = limits[key] as? [String: Any], let used = number(item["used_percent"]), (0...100).contains(used) else { return nil }
                let duration = number(item["limit_window_seconds"]).flatMap { (1...315_360_000).contains($0) ? $0 : nil }
                let label = duration.map { $0 == 604800 ? "7d" : $0 == 18000 ? "5h" : "\(Int($0 / 60))m" } ?? fallback
                let reset = number(item["reset_at"]).flatMap { (1...100_000_000_000).contains($0) ? Date(timeIntervalSince1970: $0) : nil }
                return .init(id: prefix + key, label: title + label, usedPercent: used, resetsAt: reset, durationSeconds: duration)
            }
        }
        result.quotas = windows(root["rate_limit"] as? [String: Any] ?? [:])
        if let extra = root["additional_rate_limits"] as? [[String: Any]] {
            for (index, item) in extra.prefix(20).enumerated() {
                let name = String((item["limit_name"] as? String ?? "额外额度").prefix(80))
                result.quotas += windows(item["rate_limit"] as? [String: Any] ?? [:], prefix: "extra-\(index)-", title: name + " · ")
            }
        }
        if let plan = root["plan_type"] as? String { result.plan = String(plan.prefix(80)) }
        if let credits = root["credits"] as? [String: Any] {
            if credits["unlimited"] as? Bool == true { result.credits = "不限量" }
            else if let n = number(credits["balance"]), n >= 0 { result.credits = String(format: "%.2f credits", n) }
        }
        guard !result.quotas.isEmpty || result.credits != nil else { throw CodexAccountError.invalidResponse }
        return result
    }
}
