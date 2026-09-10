import Foundation

/// 统一入口，保留不同协议和权限边界，不把余额和订阅额度混合汇总。
enum RemoteSourceCategory: String, CaseIterable, Identifiable {
    case codex, gateway, newAPI = "newapi", subAPI = "subapi"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: "Codex 官方账号"
        case .gateway: "网关上游账号"
        case .newAPI: "NewAPI 余额"
        case .subAPI: "Sub2API 余额"
        }
    }
    var detail: String {
        switch self {
        case .codex: "通过系统浏览器授权，读取个人 Codex 订阅额度；不切换桌面端当前账号。"
        case .gateway: "管理端来源：CLIProxyAPI、CPA Manager Plus、Sub2API。查看池内上游 Codex 账号及额度，需要相应管理权限。"
        case .newAPI: "用户端来源：使用 NewAPI 个人访问令牌（PAT）读取站点余额，不是 ChatGPT 订阅额度。"
        case .subAPI: "用户端来源：读取 Sub2API 站点当前用户余额；与 Sub2API 管理端的上游账号池是两个权限范围。"
        }
    }
}
