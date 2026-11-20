import Foundation

enum TaskProgressPath {
    /// 归一符号链接与 macOS 大小写不敏感文件系统中的实际名称，沿用 Foundation 路径表示。
    /// 尚未创建的文档保留绝对路径，供后续发现重试。
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
