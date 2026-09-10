import SwiftUI
import CodexMonitorCore

struct OverviewView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if store.snapshot.progress.pendingFiles > 0 {
                    Notice(text: "正在回填历史。这里是已扫描部分，不是完整总量；点刷新继续，或开启自动刷新。", warning: true)
                }
                HStack(spacing: 14) {
                    Metric(title: "\(store.window.rawValue) Token", value: Display.tokens(store.usage.total), detail: "输入 + 输出 · 不重复累加缓存")
                    Metric(title: "缓存命中", value: store.usage.cacheRatio.map { String(format:"%.1f%%", $0 * 100) } ?? "—", detail: "缓存输入 / 全部输入")
                    Metric(title: "任务 / 子代理", value: "\(store.tasks.count) / \(store.snapshot.sessions.filter(\.isSubagent).count)", detail: "已扫描范围内的累计数量")
                }
                if store.snapshot.sessions.isEmpty {
                    EmptyPanel(title: "还没有可展示的对话", detail: "选择 Codex 数据目录，或者在设置中打开演示模式查看界面。", icon: "tray")
                    HStack {
                        Button("选择数据目录") { store.chooseCodexHome() }.buttonStyle(.borderedProminent)
                        Button("查看演示") { if !store.demo { store.toggleDemo() } }
                    }
                } else {
                    Surface {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack { Text("模型用量").font(.headline); Spacer(); Text("\(store.window.rawValue)").font(.caption).foregroundStyle(.secondary) }
                            let models = LedgerMath.models(store.snapshot.sessions, since: store.since)
                            ForEach(models) { row in
                                HStack(spacing: 14) {
                                    Text(row.model).font(.system(.callout, design:.monospaced)).frame(width: 180,alignment:.leading).lineLimit(1)
                                    GeometryReader { geometry in
                                        RoundedRectangle(cornerRadius:3).fill(Color.blue.opacity(0.14))
                                            .overlay(alignment:.leading) {
                                                RoundedRectangle(cornerRadius:3).fill(Color.blue.opacity(0.68))
                                                    .frame(width: geometry.size.width * CGFloat(Double(row.tokens.total) / Double(max(1, models.first?.tokens.total ?? 1))))
                                            }
                                    }.frame(height:7)
                                    Text(Display.tokens(row.tokens.total)).monospacedDigit().frame(width:85,alignment:.trailing)
                                }
                            }
                            if models.isEmpty { Text("所选时间范围没有可归属的 Token 事件。").foregroundStyle(.secondary) }
                        }
                    }
                    Surface {
                        VStack(alignment:.leading,spacing:14) {
                            Text("用量构成").font(.headline)
                            HStack {
                                component("未缓存输入", store.usage.uncached)
                                Divider().frame(height:40)
                                component("缓存输入", store.usage.cached)
                                Divider().frame(height:40)
                                component("输出（含推理）", store.usage.output)
                            }
                            let value = store.cost
                            Divider()
                            HStack {
                                Text("API 参考估算").foregroundStyle(.secondary)
                                Spacer()
                                if store.prices.models.isEmpty { Text("未配置价格").foregroundStyle(.secondary) }
                                else { Text("\(store.prices.currency) \(value.amount, specifier: "%.4f")").monospacedDigit() }
                            }
                            Text(value.excludedTokens > 0 ? "有 \(Display.tokens(value.excludedTokens)) Token 因未知模型、历史基线或超出费率适用范围未计价。不是订阅账单。" : "使用本地配置费率，不含工具费用或特殊计费档位，不是订阅账单。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Surface {
                        VStack(alignment:.leading,spacing:14) {
                            HStack { Text("额度 · 本地日志快照").font(.headline); Spacer(); Text("不是实时账户查询").font(.caption).foregroundStyle(.secondary) }
                            if store.quota.isEmpty { Text("日志中没有额度信息。不会为此读取登录凭据。").foregroundStyle(.secondary) }
                            ForEach(store.quota) { q in
                                HStack {
                                    Text(q.minutes >= 1440 ? "\(q.minutes / 1440) 天窗口" : "\(q.minutes / 60) 小时窗口").frame(width:100,alignment:.leading)
                                    ProgressView(value:q.remainingPercent,total:100).tint(.blue)
                                    Text("\(q.remainingPercent,specifier:"%.0f")% 剩余").monospacedDigit().frame(width:95,alignment:.trailing)
                                }
                                if let observed = q.observedAt {
                                    Text("记录时间：\(observed.formatted(date:.abbreviated,time:.shortened))\(q.resetsAt.map { " · 重置时间：" + $0.formatted(date:.abbreviated,time:.shortened) } ?? "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !store.snapshot.progress.issues.isEmpty {
                    Notice(text:store.snapshot.progress.issues.joined(separator:"\n"),warning:true)
                }
            }.padding(24)
        }
    }
    private func component(_ label: String, _ value: Int64) -> some View {
        VStack(alignment:.leading,spacing:7) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(Display.tokens(value)).font(.title3.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
