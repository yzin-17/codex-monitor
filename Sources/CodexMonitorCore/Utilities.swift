import Foundation

public enum LedgerError: LocalizedError {
    case unsafePath, missingDirectory, invalidCatalog, invalidPrices, invalidArguments(String)
    public var errorDescription: String? {
        switch self {
        case .unsafePath: "拒绝访问越界路径，或将缓存写入 Codex 数据目录。"
        case .missingDirectory: "找不到 Codex 数据目录，请在设置中选择实际目录。"
        case .invalidCatalog: "目录快照格式不正确，应导入 skills/list 的 result JSON。"
        case .invalidPrices: "价格文件无效：费率必须是有限的非负数，且模型名不能重复。"
        case .invalidArguments(let text): text
        }
    }
}
public enum Paths {
    public static func url(_ path: String) -> URL {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
    }
    public static func contains(_ child: URL, in parent: URL) -> Bool {
        let p = parent.resolvingSymlinksInPath().standardizedFileURL.path
        let c = child.resolvingSymlinksInPath().standardizedFileURL.path
        return c == p || c.hasPrefix(p == "/" ? "/" : p + "/")
    }
    public static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexMonitor")
    }
}

enum JSONValue {
    static func dict(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    static func text(_ value: Any?) -> String? { value as? String }
    static func int(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, CFTypeIDNotBool(n) else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d >= 0, d < 9_000_000_000_000_000, floor(d) == d else { return nil }
        return n.int64Value
    }
    private static func CFTypeIDNotBool(_ n: NSNumber) -> Bool {
        String(cString: n.objCType) != "c" || (n !== kCFBooleanTrue && n !== kCFBooleanFalse)
    }
    static func tokens(_ value: Any?) -> Tokens? {
        let d = dict(value)
        guard let input = int(d["input_tokens"] ?? d["inputTokens"]),
              let output = int(d["output_tokens"] ?? d["outputTokens"]) else { return nil }
        return Tokens(input: input, cached: int(d["cached_input_tokens"] ?? d["cachedInputTokens"]) ?? 0,
                      output: output, reasoning: int(d["reasoning_output_tokens"] ?? d["reasoningOutputTokens"]) ?? 0)
    }
    static func stringContent(_ value: Any?) -> String {
        if let s = value as? String { return s }
        return (value as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    static func date(_ value: Any?) -> Date? {
        if let s = value as? String {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        if let n = value as? NSNumber, n.doubleValue.isFinite {
            return Date(timeIntervalSince1970: n.doubleValue > 100_000_000_000 ? n.doubleValue / 1000 : n.doubleValue)
        }
        return nil
    }
}
import CoreFoundation

public enum Display {
    public static func tokens(_ n: Int64) -> String {
        if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
    public static func safe(_ s: String, limit: Int = 240) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(limit))
    }
}

/// 非加密指纹只用于缓存变化检测，不能用作匿名化或安全校验。
func fingerprint(_ data: Data) -> String {
    var hash: UInt64 = 14695981039346656037
    for byte in data { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
    return String(hash, radix: 16)
}

public enum PrivateFile {
    public static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // 临时文件在写入前就限制权限，不使用默认 umask 保护敏感元数据。
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fm.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
#if os(Linux)
import Glibc
#else
import Darwin
#endif
