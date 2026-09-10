import AppKit
import SwiftUI
import CodexMonitorCore

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @State private var confirmReindex = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                Notice(text:"默认离线模式：不提供网页登录、API Key 输入或远程账号监测。没有网络请求或 Codex 子进程调用；原始日志只读，派生缓存只写入本应用目录。")
                Surface {
                    VStack(alignment:.leading,spacing:14) {
                        Text("数据目录").font(.headline)
                        HStack {
                            Text(store.configuration.codexHome).font(.system(.callout,design:.monospaced)).textSelection(.enabled)
                            Spacer(); Button("选择…") { store.chooseCodexHome() }
                        }
                        Text("包含 sessions、archived_sessions 和可选 state_*.sqlite 的目录。支持自定义 CODEX_HOME，但不会读取 auth.json。").font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Toggle("本地 Skills 分析",isOn:Binding(get:{store.configuration.skillsEnabled},set:{ value in
                            var c = store.configuration; c.skillsEnabled = value; store.apply(c)
                        }))
                        Text("首版采用本地发现，默认不推断 enabled。切换开关后扫描器会重建对应口径缓存。").font(.caption).foregroundStyle(.secondary)
                        ForEach(store.configuration.projects,id:\.self) { path in
                            HStack { Label(path,systemImage:"folder").font(.caption); Spacer(); Button("移除") { var c=store.configuration; c.projects.removeAll{$0==path}; store.apply(c) } }
                        }
                        HStack { Button("添加项目…") { store.addProject() }; Button("添加 Skills 根目录…") { store.addSkillRoot() } }
                        ForEach(store.configuration.skillRoots,id:\.self) { path in
                            HStack { Text(path).font(.caption); Spacer(); Button("移除") { var c=store.configuration; c.skillRoots.removeAll{$0==path}; store.apply(c) } }
                        }
                        Divider()
                        Button("导入 skills/list 离线目录快照…") { store.importCatalog() }
                        Text(store.catalogImportedAt.map { "快照导入于：" + $0.formatted() + "（仅本次运行有效）" } ?? "可从已有 Codex 调试输出导入 JSON；不是必须，不会自动执行命令。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Surface {
                    VStack(alignment:.leading,spacing:14) {
                        Text("成本参考").font(.headline)
                        HStack {
                            Text("已配置 \(store.prices.models.count) 个模型 · \(store.prices.currency)")
                            Spacer(); Button("导入本地价格…") { store.importPrices() }
                        }
                        Text("未配置、无法归属模型或超出适用上下文的用量不猜价。例子见源码 examples/prices.example.json。费率变化不会触发网络查询。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Surface {
                    VStack(alignment:.leading,spacing:14) {
                        Text("显示与扫描").font(.headline)
                        Toggle("隐私显示：隐藏标题与项目路径",isOn:$store.privacyMode)
                        Toggle("15 秒自动刷新（低电量或严重温控时暂停）",isOn:$store.autoRefresh)
                        HStack {
                            Button(store.demo ? "退出演示模式" : "查看演示数据") { store.toggleDemo() }
                            Button("显示 / 隐藏浮动条") { store.hud.toggle(store:store) }
                            Spacer()
                            Button("重新索引…") { confirmReindex = true }
                        }
                        Text("浮动条可拖动，不会修改 Codex 界面或开启调试端口。首次扫描分批回填；未完成会明确提示，不把局部小计称作完整历史。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Surface {
                    VStack(alignment:.leading,spacing:10) {
                        Text("安全边界").font(.headline)
                        Text("缓存包含模型、用量、会话 ID、Skill 路径与证据偏移，不保存对话正文、工具输出、密码或 Cookie。缓存以 0700 目录 / 0600 文件保存，但不是加密保险箱。")
                        Text("导出报告默认隐藏会话标题、路径与原始 ID。仅在点击对话按钮时通过 codex:// 打开 Codex；不会自动发送消息。")
                        Text("这是源码首版。当前 Linux 环境验证了统计核心；macOS 图形界面与真实 Codex 数据的验收状态详见 docs/VALIDATION.md。")
                    }.font(.callout).foregroundStyle(.secondary)
                }
            }.padding(24)
        }
        .alert("重建本应用扫描缓存？",isPresented:$confirmReindex) {
            Button("取消",role:.cancel) {}
            Button("重建",role:.destructive) { store.reindex() }
        } message:{ Text("不会删除 Codex 会话。清除本应用检查点后，下次刷新从头扫描，可能需要多轮。") }
    }
}
