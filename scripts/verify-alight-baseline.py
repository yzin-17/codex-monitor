#!/usr/bin/env python3
"""校验固定上游与明确允许的增量；--apply 只用于首次接入，日常构建不重写代码。"""
from pathlib import Path
import hashlib
import json
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = 'ec9363d56a3692903f5ccb7462df2a0fbafc7297'


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args])


def replace_once(text, before, after):
    if text.count(before) != 1:
        raise RuntimeError(f'上游锚点不唯一，拒绝改写: {before[:100]!r}')
    return text.replace(before, after, 1)


PREFIX = '''# Codex Monitor · ALight 基线定制版

本分支以 **ALight v0.1.17 原版源码**为基础，保留原版刘海 HUD、展开/收起动画、深色面板、Codex/Radar/远程账号页面、模型价格、额度和统计。此前独立重写的侧栏主窗口已经移除，不再作为应用基线。

新增功能仅为同一详情面板里的 **Skills** Tab 与设置入口：目录、证据分级、7/30 天筛选、关联对话跳转和脱敏报告。Skills 手动触发本地分片分析，不调用模型；它的解析核心不参与原版 Token/成本计算。

## 安装本定制版

```bash
git clone -b rework/alight-baseline-skills https://github.com/yzin-17/codex-monitor.git
cd codex-monitor
./scripts/install.sh
# 已安装上一版时，先退出 Codex Monitor，然后：
./scripts/install.sh --replace
```

安装到 `~/Applications/CodexMonitor.app`；Bundle ID、偏好、Keychain service 与派生数据和 ALight 原版隔离。不会强制结束 Codex/ChatGPT，不移除 quarantine。应用采用 ad-hoc 签名，未公证。

首次展开原版 HUD，在设置 → Skills 添加项目与真实 Skill 目录，然后进入 Skills 点击分析。需要更多历史时点击继续；文件存在不代表已启用，读取成功不代表执行有效，逐 Skill Token 不可用。

**安全口径改变：完整原版包含网络价格源、Radar、远程账户和本机 app-server 功能；不能再把整个 App 称为纯离线。** 不需要的功能由用户在原版设置里关闭。本次先保留，不静默删减。

来源与许可见 [UPSTREAM.md](UPSTREAM.md)，变更与验收见 [重做记录](docs/ALIGHT_REWORK.md)。下面保留上游 README 原文；其中原版应用名称/安装说明应以本节定制版说明为准。

---

'''

INSTALL = '''#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$ROOT_DIR/dist/CodexMonitor.app"
INSTALL_DIR="${CODEX_NOTCH_INSTALL_DIR:-$HOME/Applications}"
TARGET_APP="$INSTALL_DIR/CodexMonitor.app"
replace=0
case "${1:-}" in
  '') ;;
  --replace) replace=1 ;;
  *) echo "用法：$0 [--replace]" >&2; exit 2 ;;
esac
[[ -d "$SOURCE_APP" ]] || { echo '请先运行 ./scripts/build-app.sh' >&2; exit 1; }
if pgrep -x CodexMonitor >/dev/null; then
  echo '请先正常退出 Codex Monitor，再安装。不会强制结束任何应用。' >&2
  exit 1
fi
codesign --verify --deep --strict "$SOURCE_APP"
mkdir -p "$INSTALL_DIR"
if [[ -e "$TARGET_APP" ]]; then
  [[ "$replace" == 1 ]] || { echo '应用已存在，请显式传入 --replace。' >&2; exit 1; }
  BACKUP_DIR="$(mktemp -d "$INSTALL_DIR/CodexMonitor-backup-$(date +%Y%m%d-%H%M%S).XXXXXX")"
  mv "$TARGET_APP" "$BACKUP_DIR/CodexMonitor.app"
  echo "旧版已备份：$BACKUP_DIR"
fi
ditto "$SOURCE_APP" "$TARGET_APP"
codesign --verify --deep --strict "$TARGET_APP"
open "$TARGET_APP"
echo "已安装：$TARGET_APP"
'''


def expected(path, data):
    if path == 'README.md':
        return PREFIX.encode() + data
    if path == 'scripts/install-user-app.sh':
        return INSTALL.encode()
    if not (path.endswith('.swift') or path == 'scripts/build-app.sh'):
        return data
    s = data.decode('utf-8')
    # 只隔离应用身份和派生目录，不更改页面文案、布局、颜色和数据算法。
    s = s.replace('com.alight.codexnotch', 'dev.yzin.codexmonitor.alight')
    s = s.replace('appendingPathComponent("codex监测"', 'appendingPathComponent("CodexMonitor-ALight"')
    s = s.replace('appendingPathComponent("CodexNotch"', 'appendingPathComponent("CodexMonitor-ALight"')
    if path == 'scripts/build-app.sh':
        s = replace_once(s, 'APP_NAME="codex监测"', 'APP_NAME="CodexMonitor"')
        s = replace_once(s, 'cd "$ROOT_DIR"', 'cd "$ROOT_DIR"\nmkdir -p "$DIST_DIR"')
        s = s.replace('"$macos_dir/CodexNotch"', '"$macos_dir/CodexMonitor"')
        s = replace_once(s, '<string>CodexNotch</string>', '<string>CodexMonitor</string>')
    if path == 'Package.swift':
        s = replace_once(s, '    targets: [\n', '''    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "CodexMonitorCore", dependencies: ["CSQLite"]),
        .testTarget(name: "CodexMonitorCoreTests", dependencies: ["CodexMonitorCore", "CSQLite"]),
''')
        s = replace_once(s, '            name: "CodexNotch",\n            path:', '            name: "CodexNotch",\n            dependencies: ["CodexMonitorCore"],\n            path:')
        s = replace_once(s, 'dependencies: ["CodexNotch"]', 'dependencies: ["CodexNotch", "CodexMonitorCore"]')
    if path == 'Sources/CodexNotch/NotchIslandView.swift':
        s = replace_once(s, '    case codexRadar\n', '    case codexRadar\n    case skills\n')
        s = replace_once(s, '        case .codexRadar:\n            "Radar"', '        case .skills:\n            "Skills"\n        case .codexRadar:\n            "Radar"')
        s = replace_once(s, '    @State private var detailPage: DetailPage = .codex', '    @StateObject private var skillsModel = SkillInsightsViewModel()\n    @AppStorage("skills.enabled") private var skillsEnabled = true\n    @State private var detailPage: DetailPage = .codex')
        s = replace_once(s, '                        case .codexRadar:\n                            codexRadarContent', '                        case .skills:\n                            SkillInsightsPanelView(model: skillsModel)\n                        case .codexRadar:\n                            codexRadarContent')
        s = replace_once(s, '        .clipShape(BottomRoundedRectangle(radius: 24))', '        .clipShape(BottomRoundedRectangle(radius: 24))\n        .onChange(of: skillsEnabled) { _, enabled in\n            if !enabled { skillsModel.cancel() }\n        }')
        s = replace_once(s, '        case .codexRadar:\n            "CodexRadar"', '        case .skills:\n            "Skills"\n        case .codexRadar:\n            "CodexRadar"')
        s = replace_once(s, '        case .codexRadar:\n            return codexRadarHeaderStatus', '        case .skills:\n            return skillsModel.status\n        case .codexRadar:\n            return codexRadarHeaderStatus')
        s = replace_once(s, '        case .codexRadar:\n            codexRadarHeaderColor', '        case .skills:\n            Color(red: 0.61, green: 0.95, blue: 0.68)\n        case .codexRadar:\n            codexRadarHeaderColor')
        s = replace_once(s, '        case .codexRadar:\n            codexRadarViewModel.isRefreshing', '        case .skills:\n            skillsModel.isAnalyzing\n        case .codexRadar:\n            codexRadarViewModel.isRefreshing')
        s = replace_once(s, '        case .codexRadar:\n            "刷新 CodexRadar"', '        case .skills:\n            "本地分析 Skills / 继续回填"\n        case .codexRadar:\n            "刷新 CodexRadar"')
        s = replace_once(s, '        var pages: [DetailPage] = [.codex]', '        var pages: [DetailPage] = [.codex]\n        if skillsEnabled { pages.append(.skills) }')
        s = replace_once(s, '        case .codexRadar:\n            onCodexRadarRefresh()', '        case .skills:\n            skillsModel.analyze()\n        case .codexRadar:\n            onCodexRadarRefresh()')
    if path == 'Sources/CodexNotch/SettingsView.swift':
        s = replace_once(s, '    case codexRadar\n', '    case codexRadar\n    case skills\n')
        s = replace_once(s, '        case .codexRadar:\n            "CodexRadar"', '        case .skills:\n            "Skills"\n        case .codexRadar:\n            "CodexRadar"')
        s = replace_once(s, '        case .codexRadar:\n            "waveform.path.ecg"', '        case .skills:\n            "square.stack.3d.up"\n        case .codexRadar:\n            "waveform.path.ecg"')
        s = replace_once(s, '        case .codexRadar:\n            codexRadarSettingsContent', '        case .skills:\n            SkillInsightsSettingsView()\n        case .codexRadar:\n            codexRadarSettingsContent')
        s = replace_once(s, '.formStyle(.grouped)\n                .disabled(!settings.secretStoreReady)', '.formStyle(.grouped)\n                .disabled(selectedTab != .skills && !settings.secretStoreReady)')
    if path == "Sources/CodexNotch/SettingsView.swift":
        s = replace_once(s, '        case .codex, .launch, .about:\n', '        case .skills:\n            break\n        case .codex, .launch, .about:\n')
    if path.endswith('.swift'):
        s = s.replace('Library/Application Support/codex监测/', 'Library/Application Support/CodexMonitor-ALight/')
        s = s.replace('appendingPathComponent("codex监测/', 'appendingPathComponent("CodexMonitor-ALight/')
    if path == 'scripts/build-app.sh':
        s = replace_once(s, 'swift "$ROOT_DIR/scripts/generate-app-icon.swift"', 'ICON_BACKUP="$(mktemp "${TMPDIR:-/tmp}/codex-monitor-icon.XXXXXX")"\ncp "$ROOT_DIR/Resources/AppIcon.icns" "$ICON_BACKUP"\ntrap \'cp "$ICON_BACKUP" "$ROOT_DIR/Resources/AppIcon.icns"; rm -f "$ICON_BACKUP"\' EXIT\nswift "$ROOT_DIR/scripts/generate-app-icon.swift"')
    return s.encode()


def main():
    apply = sys.argv[1:] == ['--apply']
    if sys.argv[1:] not in ([], ['--apply']):
        raise SystemExit('用法：verify-alight-baseline.py [--apply]')
    entries = git('ls-tree', '-rz', UPSTREAM).split(b'\0')
    changed, unchanged = [], []
    for entry in entries:
        if not entry:
            continue
        metadata, raw_path = entry.split(b'\t', 1)
        mode, kind, sha = metadata.decode().split()
        if kind != 'blob':
            raise RuntimeError('不支持的上游条目')
        path = raw_path.decode()
        original = git('cat-file', 'blob', sha)
        content = expected(path, original)
        target = ROOT / path
        if apply:
            if target.read_bytes() != original:
                raise RuntimeError(f'{path} 已被修改，拒绝覆盖')
            if content != original:
                target.write_bytes(content)
        if target.read_bytes() != content:
            raise RuntimeError(f'{path} 偏离固定基线与允许的增量')
        executable = bool(target.stat().st_mode & 0o111)
        if executable != (mode == '100755'):
            raise RuntimeError(f'{path} 的执行权限改变')
        record = {'path': path, 'originalBlob': sha, 'sha256': hashlib.sha256(content).hexdigest()}
        (unchanged if original == content else changed).append(record)
    if (ROOT / 'Sources/CodexMonitorApp').exists():
        raise RuntimeError('旧独立主窗口不应保留')
    for path in list((ROOT / 'Sources/CodexMonitorCore').glob('*.swift')) + list((ROOT / 'Sources/CodexNotch').glob('SkillInsights*.swift')):
        code = path.read_text()
        if any(token in code for token in ['URLSession', 'WKWebView', 'Process()', 'SecItemCopyMatching']):
            raise RuntimeError(f'{path} 不得增加网络或凭据接口')
    report = {'upstream': UPSTREAM, 'unchanged': unchanged, 'customized': changed}
    if apply:
        output = ROOT / 'docs/upstream/alight-manifest.json'
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(f'原版文件 {len(unchanged) + len(changed)}：{len(unchanged)} 完全未改；{len(changed)} 仅允许的身份隔离/Skills 接入/安装说明改动。')


if __name__ == '__main__':
    main()
