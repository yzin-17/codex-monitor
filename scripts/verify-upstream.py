#!/usr/bin/env python3
from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parents[1]
lock=json.loads((root/'docs/UPSTREAM_LOCK.json').read_text())
for entry in lock['files']:
 p=root/entry['path']
 assert p.is_file(),f"缺失来源文件：{p}"
 assert hashlib.sha256(p.read_bytes()).hexdigest()==entry['sha256'],f"来源文件已变化，请评审后更新清单：{p}"
assert not (root/'Sources/CodexMonitorApp').exists()
s=(root/'Sources/CodexNotch/NotchIslandView.swift').read_text()
for name in ['.codex, .performance, .skills, .codexRadar','PerformancePanelView','SkillInsightsPanelView','codexRadarContent','remoteContent','balanceContent']:
 assert name in s,name
print(f"来源与功能门禁通过：{len(lock['files'])} 个来源文件。")
