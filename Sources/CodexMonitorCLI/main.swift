import Foundation
import CodexMonitorCore

@main struct LedgerCLI {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.contains("--help") || args.isEmpty {
                print("""
                Codex Monitor 0.1.0 — 离线 Codex 对话与 Skills 分析
                用法：codex-monitor --home ~/.codex [--project /path] [--skill-root /path]
                                     [--format json|markdown] [--passes 50] [--no-skills]
                      codex-monitor --demo [--format json|markdown]
                默认不写缓存、不调用 Codex 子进程。报告隐藏会话标题、路径和原始 ID。
                """)
                return
            }
            var config = LedgerConfiguration(); var format = "markdown"; var passes = 1; var demo = false; var i = 0
            while i < args.count {
                let arg = args[i]
                switch arg {
                case "--demo": demo = true
                case "--no-skills": config.skillsEnabled = false
                case "--home", "--project", "--skill-root", "--format", "--passes":
                    i += 1
                    guard i < args.count else { throw LedgerError.invalidArguments("\(arg) 缺少值") }
                    switch arg {
                    case "--home": config.codexHome = args[i]
                    case "--project": config.projects.append(args[i])
                    case "--skill-root": config.skillRoots.append(args[i])
                    case "--format":
                        guard ["json", "markdown"].contains(args[i]) else { throw LedgerError.invalidArguments("format 只支持 json 或 markdown") }
                        format = args[i]
                    default:
                        guard let value = Int(args[i]), (1...1000).contains(value) else { throw LedgerError.invalidArguments("passes 应为 1...1000") }
                        passes = value
                    }
                default: throw LedgerError.invalidArguments("未知参数：\(arg)")
                }
                i += 1
            }
            let snapshot: LedgerSnapshot
            if demo { snapshot = Demo.snapshot() }
            else {
                let engine = AnalysisEngine(); var current = LedgerSnapshot()
                for _ in 0..<passes {
                    current = try await engine.refresh(config)
                    if current.progress.pendingFiles == 0 { break }
                }
                snapshot = current
            }
            if format == "json" { FileHandle.standardOutput.write(try Reports.json(snapshot)); print() }
            else { print(Reports.markdown(snapshot)) }
            if snapshot.progress.pendingFiles > 0 {
                FileHandle.standardError.write(Data("仍有未追平日志；本次不是完整历史总计。可增大 --passes。\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("错误：\(error.localizedDescription)\n".utf8)); exit(1)
        }
    }
}
