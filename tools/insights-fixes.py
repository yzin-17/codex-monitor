from pathlib import Path
import subprocess
root=Path.cwd()
def edit(path,old,new):
    p=root/path;s=p.read_text();assert old in s,path;p.write_text(s.replace(old,new,1))
edit('Sources/CodexNotch/CLIResumeTransport.swift','Thread.sleep(forTimeInterval: 0.04)','try? await Task.sleep(for: .milliseconds(40))')
edit('Sources/CodexNotch/UsageViewModel.swift','            .store(in: &cancellables)\n    }','            .store(in: &cancellables)\n        // 恢复已经明确启用的检查，不依赖用户打开某个页面。\n        _ = publicInsights\n        _ = cliResume\n    }')
edit('Sources/CodexNotch/CLIResumeModels.swift','"-c", "sandbox_workspace_write.network_access=false"]','"-c", "sandbox_workspace_write.network_access=false",\n                    "-c", "sandbox_workspace_write.writable_roots=[]"]')
edit('Sources/CodexNotch/CLIResumeModels.swift','        if let effort = context.effort, ["minimal", "low", "medium", "high", "xhigh", "max"].contains(effort) {','        if let effort = context.effort {\n            guard ["minimal", "low", "medium", "high", "xhigh", "max"].contains(effort) else { throw CLIResumeError.unsupportedSession }')
# 常规 CI 的新截图清单在正式发布时更新；避免 Actions 自带凭据修改工作流。
p=root/'.github/workflows/ci.yml';p.write_bytes(subprocess.check_output(['git','show','HEAD:.github/workflows/ci.yml']))
edit('Sources/CodexNotch/CLIResumeTransport.swift','JSONSerialization.data(withJSONObject: object); data.append(10)','JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]); data.append(10)')
edit('Sources/CodexNotch/PublicInsightsView.swift','                    content(snapshot, now: context.date)','                    VStack(alignment: .leading, spacing: 6) {\n                        content(snapshot, now: context.date)\n                    }.frame(maxWidth: .infinity, alignment: .leading)')
edit('Sources/CodexNotch/CLIResumeModels.swift','              !context.model.isEmpty, context.model.utf8.count < 150,','              !context.model.isEmpty, !context.model.hasPrefix("-"), context.model.utf8.count < 150,')
p=root/'Tests/CodexNotchRegressionTests/main.swift';s=p.read_text();s=s.replace('"0.3.2"','"0.4.0"').replace('expose version 0.3.2','expose version 0.4.0');p.write_text(s)
edit('Tests/CodexNotchTests/PublicInsightsTests.swift','    try await Task.sleep(for: .milliseconds(100))\n    #expect(store.snapshots[.observatory]?.summary == "fixture")','    let deadline = ProcessInfo.processInfo.systemUptime + 5\n    while store.snapshots[.observatory] == nil && ProcessInfo.processInfo.systemUptime < deadline {\n        try await Task.sleep(for: .milliseconds(20))\n    }\n    #expect(store.snapshots[.observatory]?.summary == "fixture")')
edit('Tests/CodexNotchTests/CLIResumeTests.swift','    #expect(arguments.contains("sandbox_workspace_write.network_access=false"))','    #expect(arguments.contains("sandbox_workspace_write.network_access=false"))\n    #expect(arguments.contains("sandbox_workspace_write.writable_roots=[]"))')
edit('Tests/CodexNotchTests/CLIResumeTests.swift','    context.sandbox = "danger-full-access"','    context.model = "--yolo"\n    #expect(throws: CLIResumeError.unsupportedSession) { try CLIResumePolicy.arguments(context: context, sandbox: "read-only") }\n    context.model = "gpt-test"; context.effort = "unsupported-future-effort"\n    #expect(throws: CLIResumeError.unsupportedSession) { try CLIResumePolicy.arguments(context: context, sandbox: "read-only") }\n    context.effort = "high"\n    context.sandbox = "danger-full-access"')
