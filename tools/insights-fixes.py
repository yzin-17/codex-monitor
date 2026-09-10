from pathlib import Path
import subprocess
root=Path.cwd()
def edit(path,old,new):
    p=root/path;s=p.read_text();assert old in s,path;p.write_text(s.replace(old,new,1))
edit('Sources/CodexNotch/CLIResumeTransport.swift','Thread.sleep(forTimeInterval: 0.04)','try? await Task.sleep(for: .milliseconds(40))')
edit('Sources/CodexNotch/UsageViewModel.swift','            .store(in: &cancellables)\n    }','            .store(in: &cancellables)\n        // 恢复已经明确启用的检查，不依赖用户打开某个页面。\n        _ = publicInsights\n        _ = cliResume\n    }')
edit('Sources/CodexNotch/CLIResumeModels.swift','"-c", "sandbox_workspace_write.network_access=false"]','"-c", "sandbox_workspace_write.network_access=false",\n                    "-c", "sandbox_workspace_write.writable_roots=[]"]')
edit('Sources/CodexNotch/CLIResumeModels.swift','        if let effort = context.effort, ["minimal", "low", "medium", "high", "xhigh", "max"].contains(effort) {','        if let effort = context.effort {\n            guard ["minimal", "low", "medium", "high", "xhigh", "max"].contains(effort) else { throw CLIResumeError.unsupportedSession }')
p=root/'.github/workflows/ci.yml';p.write_bytes(subprocess.check_output(['git','show','HEAD:.github/workflows/ci.yml']))
