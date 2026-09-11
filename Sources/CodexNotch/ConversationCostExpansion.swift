import AppKit
import Combine
import SwiftUI

@MainActor final class ConversationCostDetailModel: ObservableObject {
    @Published private(set) var detail: ConversationCostDetails?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private let loader: ConversationCostLoader?
    private var worker: Task<ConversationCostDetails, Error>?
    private var generation = 0

    init(loader: ConversationCostLoader?, preview: ConversationCostDetails? = nil) {
        self.loader = loader; detail = preview
    }
    func cancel() { generation += 1; worker?.cancel(); worker = nil; loading = false }
    func load(id: String, skillsEnabled: Bool) async {
        guard let loader, !loading else { return }
        generation += 1; let current = generation
        loading = true; error = nil
        let task = Task.detached(priority: .utility) {
            try loader.load(rootID: id, includeSkills: skillsEnabled, shouldCancel: { Task.isCancelled })
        }
        worker = task
        defer { if generation == current { loading = false; worker = nil } }
        do {
            let next = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            guard generation == current, !Task.isCancelled else { return }
            detail = next
        } catch is CancellationError { }
        catch { if generation == current { self.error = "读取失败；未将缺失数据当作零费用。" } }
    }
}

/// 行内明细，不打开另一个主窗口，不改变原版 Token 构成弹窗。
@MainActor struct ConversationCostExpansion: View {
    let task: CodexTask
    let skillsEnabled: Bool
    @StateObject private var model: ConversationCostDetailModel
    init(task: CodexTask, skillsEnabled: Bool, makeLoader: @escaping () -> ConversationCostLoader?,
         preview: ConversationCostDetails? = nil) {
        self.task = task; self.skillsEnabled = skillsEnabled
        _model = StateObject(wrappedValue: ConversationCostDetailModel(loader: makeLoader(), preview: preview))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                Text("代理费用明细").font(.system(size: 11, weight: .bold))
                Spacer()
                if model.loading { ProgressView().controlSize(.mini) }
                Button(model.detail?.pending == true ? "继续扫描" : "刷新明细") {
                    Task { await model.load(id: task.id, skillsEnabled: skillsEnabled) }
                }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.loading)
            }
            if let error = model.error { note(error) }
            if let detail = model.detail {
                ForEach(detail.agents) { agent in agentRow(agent) }
                if !detail.agents.isEmpty {
                    HStack {
                        Text("已观察任务合计").fontWeight(.semibold)
                        Spacer()
                        Text(Formatters.compactTokens(detail.usage.totalTokens))
                        Text(Formatters.estimatedCostUSD(detail.usage.costUSD)).foregroundStyle(.cyan)
                    }.monospacedDigit()
                    if detail.usage.totalTokens != task.tokenCount {
                        note("列表快照 \(Formatters.compactTokens(task.tokenCount))，明细 \(Formatters.compactTokens(detail.usage.totalTokens))。扫描范围或记录时间不同，尚未完全对齐。")
                    }
                }
                ForEach(detail.diagnostics, id: \.self) { note($0) }
                if detail.pending { note("结果尚未完整。继续扫描会从内存游标接着读取。") }
                Divider()
                Text("Skill 关联回合费用").font(.system(size: 11, weight: .bold))
                if !skillsEnabled { note("Skills 已关闭。") }
                else if detail.skills.isEmpty {
                    note("当前已读日志没有可配对的 Skill 成功读取及回合用量；独立 Skill 费用不可归属，不显示为 $0。")
                } else {
                    ForEach(detail.skills) { skill in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(skill.name).fontWeight(.semibold).lineLimit(1).help(skill.id)
                                Spacer(minLength: 6)
                                Text("\(skill.turns) 回合 · \(skill.agentIDs.count) 个代理").foregroundStyle(.secondary)
                                Text(Formatters.estimatedCostUSD(skill.usage.costUSD)).foregroundStyle(.cyan)
                            }
                            Text("\(Formatters.compactTokens(skill.usage.totalTokens)) Token · 非独占费用")
                                .foregroundStyle(.secondary)
                        }.monospacedDigit()
                    }
                }
                note("Skill 金额包含该回合所有模型请求，不代表 Skill 额外收费。多个 Skill 可重叠，不相加、不计入上方任务合计。")
                Text("API 等价估算 · \(TokenCostCatalog.priceVersion)").foregroundStyle(.secondary)
            } else if !model.loading {
                note("费用明细尚未读取。")
            }
        }
        .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.88))
        .task(id: skillsEnabled) { model.cancel(); await model.load(id: task.id, skillsEnabled: skillsEnabled) }
        .onDisappear { model.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .tokenPricingDidChange)) { _ in model.objectWillChange.send() }
    }
    private func agentRow(_ agent: AgentCostDetail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(agent.depth == 0 ? "主代理" : "子代理 \(agent.id.prefix(8))")
                    .fontWeight(.semibold).help(agent.id)
                Text(agent.model).lineLimit(1).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(agent.hasUsage ? Formatters.compactTokens(agent.usage.totalTokens) : "—")
                Text(agent.hasUsage ? Formatters.estimatedCostUSD(agent.usage.costUSD) : "未读到用量")
                    .foregroundStyle(agent.hasUsage ? .cyan : .secondary)
                    .help(agent.hasUsage ? "API 等价费用估算" : "已识别该代理，但当前扫描范围内没有读到可独立归属给它的 token_count 记录；不会按 $0 处理。")
            }.monospacedDigit()
            if agent.depth > 1 { Text("第 \(agent.depth) 层 · 上级 \(agent.parentID?.prefix(8) ?? "未知")").foregroundStyle(.secondary) }
            if agent.usage.unpricedTokens > 0 {
                note("\(Formatters.compactTokens(agent.usage.unpricedTokens)) Token 缺少价格或明细，未计入金额。")
            } else if !agent.complete { note("日志仍未完整读取。") }
            else if !agent.hasUsage { note("已识别代理身份，但日志没有该代理可独立归属的 token_count；费用保持未知。") }
        }
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
    }
}
