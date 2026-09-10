#!/usr/bin/env python3
"""固定基线导入后的兼容补丁；只修改目标源码并更新来源哈希。"""
from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parents[1]
f=root/'Sources/CodexNotch/SkillSessionAnalyzer.swift'
s=f.read_text()
old='                    as: [ThreadRow].self,\n                    readOnly: true'
assert s.count(old)==1
# ALight 的 SQLiteJSONReader 已使用 SQLITE_OPEN_READONLY，不需要 donor 的额外参数。
f.write_text(s.replace(old,'                    as: [ThreadRow].self'))
shell=(root/'Sources/CodexNotch/Shell.swift').read_text()
assert 'let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX' in shell
lockfile=root/'docs/UPSTREAM_LOCK.json'
lock=json.loads(lockfile.read_text())
for entry in lock['files']:
 entry['sha256']=hashlib.sha256((root/entry['path']).read_bytes()).hexdigest()
 entry['modified']=entry['sha256']!=entry['source_sha256']
lockfile.write_text(json.dumps(lock,ensure_ascii=False,indent=2)+'\n')
