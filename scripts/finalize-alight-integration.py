"""一次性收尾：补齐公开缓存路径隔离，并让上游图标生成不污染工作区。"""
from pathlib import Path
import hashlib
import json
import runpy
import subprocess

check = Path('scripts/verify-alight-baseline.py')
old = runpy.run_path(str(check))
source = check.read_text()
anchor = '    return s.encode()\n'
assert source.count(anchor) == 1
icon_command = 'swift "$ROOT_DIR/scripts/generate-app-icon.swift"'
icon_backup = '''ICON_BACKUP="$(mktemp "${TMPDIR:-/tmp}/codex-monitor-icon.XXXXXX")"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$ICON_BACKUP"
trap 'cp "$ICON_BACKUP" "$ROOT_DIR/Resources/AppIcon.icns"; rm -f "$ICON_BACKUP"' EXIT
'''
patch = '''    if path.endswith('.swift'):
        s = s.replace('Library/Application Support/codex监测/', 'Library/Application Support/CodexMonitor-ALight/')
        s = s.replace('appendingPathComponent("codex监测/', 'appendingPathComponent("CodexMonitor-ALight/')
    if path == 'scripts/build-app.sh':
'''
patch += '        s = replace_once(s, ' + repr(icon_command) + ', ' + repr(icon_backup + icon_command) + ')\n'
check.write_text(source.replace(anchor, patch + anchor, 1))
new = runpy.run_path(str(check))
unchanged, changed = [], []
for entry in old['git']('ls-tree', '-rz', old['UPSTREAM']).split(b'\0'):
    if not entry:
        continue
    metadata, raw_path = entry.split(b'\t', 1)
    mode, kind, sha = metadata.decode().split()
    assert kind == 'blob'
    name = raw_path.decode()
    path = Path(name)
    original = old['git']('cat-file', 'blob', sha)
    assert path.read_bytes() == old['expected'](name, original), name
    expected = new['expected'](name, original)
    if expected != path.read_bytes():
        path.write_bytes(expected)
        print('隔离/构建收尾：', name)
    record = {'path': name, 'originalBlob': sha, 'sha256': hashlib.sha256(expected).hexdigest()}
    (unchanged if expected == original else changed).append(record)
manifest = Path('docs/upstream/alight-manifest.json')
manifest.write_text(json.dumps({'upstream': old['UPSTREAM'], 'unchanged': unchanged, 'customized': changed}, ensure_ascii=False, indent=2) + '\n')
subprocess.run(['python3', str(check)], check=True)
