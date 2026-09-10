#!/usr/bin/env python3
"""导入固定 ALight 原始项目，再接入 Jackie 性能与 Skills；只处理源码工作树。"""
from pathlib import Path
import argparse, hashlib, json, shutil

ALIGHT = 'ec9363d56a3692903f5ccb7462df2a0fbafc7297'
JACKIE = '6cd6c00aa7327a79a8b4256cf8ec2573375832f3'
DONORS = 'SkillCatalogLoader SkillInsightsModels SkillInsightsPanelView SkillInsightsService SkillInsightsViewModel SkillJSONLReader SkillObservationStore SkillProcessMetrics SkillSessionAnalyzer CodexSessionFileLocator CodexSkillsAppServerClient CodexRuntimeLocator PerformanceHistoryStore PerformanceModels PerformanceMonitorViewModel PerformancePanelView PerformanceSampler MonitorTheme'.split()
p = argparse.ArgumentParser()
for name in ['alight','jackie','target']: p.add_argument('--'+name, type=Path, required=True)
a = p.parse_args(); base=a.alight.resolve(); donor=a.jackie.resolve(); root=a.target.resolve()
assert root not in [base,donor,Path('/')]
root.mkdir(parents=True,exist_ok=True)
own_license = (root/'LICENSE').read_text() if (root/'LICENSE').exists() else ''
for name in ['Sources','Tests','scripts','examples','docs','Resources']:
    if (root/name).exists(): shutil.rmtree(root/name)
for entry in base.iterdir():
    if entry.name == '.git': continue
    if entry.is_dir(): shutil.copytree(entry,root/entry.name,dirs_exist_ok=True)
    else: shutil.copy2(entry,root/entry.name)
S=root/'Sources/CodexNotch'
for name in DONORS: shutil.copy2(donor/'Sources/CodexNotch'/f'{name}.swift',S/f'{name}.swift')
def edit(path,old,new,count=1):
    f=root/path; text=f.read_text()
    assert text.count(old)==count, f'迁移锚点不匹配：{path}: {old[:80]}'
    f.write_text(text.replace(old,new))
def write(path,text,executable=False):
    f=root/path; f.parent.mkdir(parents=True,exist_ok=True); f.write_text(text)
    if executable: f.chmod(0o755)

r=(donor/'Sources/CodexNotch/RefreshInfrastructure.swift').read_text()
write('Sources/CodexNotch/PerformanceCadence.swift','import Foundation\n\n'+r[r.index('struct RefreshEnvironment:'):r.index('struct RefreshCadenceDecision:')]+r[r.index('enum PerformanceCadencePolicy {'):r.index('enum AdaptiveRefreshPolicy {')])
f=(donor/'Sources/CodexNotch/Formatters.swift').read_text(); start=f.index('    static func compactTokensEnglish('); end=f.index('\n    static func ',start+10)
write('Sources/CodexNotch/SkillFormatters.swift','import Foundation\n\nextension Formatters {\n'+f[start:end]+'\n}\n')

path='Sources/CodexNotch/CodexNotchSettings.swift'
edit(path,'        static let codexRadarEnabled = "codexRadarEnabled"','        static let skillInsightsEnabled = "skillInsightsEnabled"\n        static let performanceMonitoringEnabled = "performanceMonitoringEnabled"\n        static let codexRadarEnabled = "codexRadarEnabled"')
edit(path,'    @Published var codexRadarEnabled: Bool {','    @Published var skillInsightsEnabled: Bool {\n        didSet { defaults.set(skillInsightsEnabled, forKey: Keys.skillInsightsEnabled) }\n    }\n\n    @Published var performanceMonitoringEnabled: Bool {\n        didSet { defaults.set(performanceMonitoringEnabled, forKey: Keys.performanceMonitoringEnabled) }\n    }\n\n    @Published var codexRadarEnabled: Bool {')
edit(path,'        self.codexRadarEnabled = defaults.object(forKey: Keys.codexRadarEnabled) as? Bool ?? false','        self.skillInsightsEnabled = defaults.object(forKey: Keys.skillInsightsEnabled) as? Bool ?? true\n        self.performanceMonitoringEnabled = defaults.object(forKey: Keys.performanceMonitoringEnabled) as? Bool ?? false\n        self.codexRadarEnabled = defaults.object(forKey: Keys.codexRadarEnabled) as? Bool ?? false')
path='Sources/CodexNotch/SettingsView.swift'
edit(path,'    var codexRadarEnabled = false','    var skillInsightsEnabled = true\n    var performanceMonitoringEnabled = false\n    var codexRadarEnabled = false')
edit(path,'        codexRadarEnabled = settings.codexRadarEnabled','        skillInsightsEnabled = settings.skillInsightsEnabled\n        performanceMonitoringEnabled = settings.performanceMonitoringEnabled\n        codexRadarEnabled = settings.codexRadarEnabled')
edit(path,'            Toggle(isOn: $draft.showPeriodUsage) {','            Toggle(isOn: $draft.skillInsightsEnabled) {\n                HelpLabel(title: "启用 Skills 分析", help: "移植自 Jackie：本地证据、目录与周报。关闭后取消分析和定时任务；不调用模型。")\n            }\n            Toggle(isOn: $draft.performanceMonitoringEnabled) {\n                HelpLabel(title: "后台性能监控", help: "默认关闭。性能页可见时采样；开启后收起页面仍低频记录 CPU、内存，不记录对话正文。")\n            }\n            Toggle(isOn: $draft.showPeriodUsage) {')
edit(path,'        settings.showPeriodUsage = next.showPeriodUsage','        settings.skillInsightsEnabled = next.skillInsightsEnabled\n        settings.performanceMonitoringEnabled = next.performanceMonitoringEnabled\n        settings.showPeriodUsage = next.showPeriodUsage')
edit(path,'在展开页新增 CodexRadar 标签，可切换','启用 Codex Radar 页的数据源，可切换')

path='Sources/CodexNotch/NotchIslandView.swift'
edit(path,'private enum DetailPage:','enum DetailPage:')
edit(path,'    case codex\n    case codexRadar','    case codex\n    case performance\n    case skills\n    case codexRadar')
edit(path,'        case .codexRadar:\n            "Radar"','        case .performance:\n            "性能"\n        case .skills:\n            "Skills"\n        case .codexRadar:\n            "Codex Radar"')
edit(path,'    @ObservedObject var codexRadarViewModel: CodexRadarViewModel','    @ObservedObject var codexRadarViewModel: CodexRadarViewModel\n    @ObservedObject var performanceViewModel: PerformanceMonitorViewModel\n    @ObservedObject var skillInsights: SkillInsightsFeatureCoordinator')
initializer='''    init(viewModel: UsageViewModel, remoteViewModel: RemoteMonitorViewModel,
         newAPIViewModel: BalanceMonitorViewModel, subAPIViewModel: BalanceMonitorViewModel,
         codexRadarViewModel: CodexRadarViewModel, performanceViewModel: PerformanceMonitorViewModel,
         skillInsights: SkillInsightsFeatureCoordinator, overlayState: OverlayState,
         settings: CodexNotchSettings, onSettings: @escaping () -> Void,
         onLocalRefresh: @escaping () -> Void, onRemoteRefresh: @escaping () -> Void,
         onNewAPIRefresh: @escaping () -> Void, onSubAPIRefresh: @escaping () -> Void,
         onCodexRadarRefresh: @escaping () -> Void, initialPage: DetailPage = .codex) {
        self.viewModel = viewModel; self.remoteViewModel = remoteViewModel
        self.newAPIViewModel = newAPIViewModel; self.subAPIViewModel = subAPIViewModel
        self.codexRadarViewModel = codexRadarViewModel; self.performanceViewModel = performanceViewModel
        self.skillInsights = skillInsights; self.overlayState = overlayState; self.settings = settings
        self.onSettings = onSettings; self.onLocalRefresh = onLocalRefresh
        self.onRemoteRefresh = onRemoteRefresh; self.onNewAPIRefresh = onNewAPIRefresh
        self.onSubAPIRefresh = onSubAPIRefresh; self.onCodexRadarRefresh = onCodexRadarRefresh
        _detailPage = State(initialValue: initialPage)
    }

'''
edit(path,'    @State private var showsRemoteUsageInfo = false\n','    @State private var showsRemoteUsageInfo = false\n\n'+initializer)
edit(path,'                        case .codexRadar:\n                            codexRadarContent','                        case .performance:\n                            ScrollView(.vertical) { PerformancePanelView(viewModel: performanceViewModel) }\n                        case .skills:\n                            if settings.skillInsightsEnabled {\n                                SkillInsightsPanelView(viewModel: skillInsights)\n                            } else {\n                                VStack(spacing: 12) {\n                                    Text("Skills 分析已关闭")\n                                    Button("打开设置", action: onSettings)\n                                }.frame(maxWidth: .infinity, maxHeight: .infinity)\n                            }\n                        case .codexRadar:\n                            codexRadarContent')
edit(path,'        .clipShape(BottomRoundedRectangle(radius: 24))','        .clipShape(BottomRoundedRectangle(radius: 24))\n        .onAppear { synchronizeExtensionVisibility() }\n        .onChange(of: detailPage) { _, _ in synchronizeExtensionVisibility() }\n        .onChange(of: overlayState.detailPresentationPhase) { _, _ in synchronizeExtensionVisibility() }\n        .onDisappear { performanceViewModel.setDetailVisible(false) }')
edit(path,'    private var showsDetailContent: Bool {','    private func synchronizeExtensionVisibility() {\n        let visible = overlayState.detailPresentationPhase.showsContent\n        performanceViewModel.setDetailVisible(visible && selectedPage == .performance)\n        if visible && selectedPage == .skills { skillInsights.refreshWhenPresented() }\n    }\n\n    private var showsDetailContent: Bool {')
edit(path,'        case .codexRadar:\n            "CodexRadar"','        case .performance:\n            "性能监测"\n        case .skills:\n            "Skill Insights"\n        case .codexRadar:\n            "CodexRadar"')
edit(path,'        case .codexRadar:\n            return codexRadarHeaderStatus','        case .performance:\n            return performanceViewModel.isRefreshing ? "采样中" : "本机进程"\n        case .skills:\n            return skillInsights.isAnalyzing ? "分析中" : skillInsights.snapshot.quality.rawValue\n        case .codexRadar:\n            return codexRadarHeaderStatus')
edit(path,'        case .codexRadar:\n            codexRadarHeaderColor','        case .performance:\n            MonitorTheme.radarBaseline\n        case .skills:\n            MonitorTheme.healthy\n        case .codexRadar:\n            codexRadarHeaderColor')
edit(path,'        case .codexRadar:\n            codexRadarViewModel.isRefreshing','        case .performance:\n            performanceViewModel.isRefreshing\n        case .skills:\n            skillInsights.isAnalyzing\n        case .codexRadar:\n            codexRadarViewModel.isRefreshing')
edit(path,'        case .codexRadar:\n            "刷新 CodexRadar"','        case .performance:\n            "刷新性能采样"\n        case .skills:\n            "分析最近 7 天 Skills"\n        case .codexRadar:\n            "刷新 CodexRadar"')
edit(path,'        var pages: [DetailPage] = [.codex]\n        if settings.codexRadarEnabled {\n            pages.append(.codexRadar)\n        }','        var pages: [DetailPage] = [.codex, .performance, .skills, .codexRadar]')
edit(path,'        case .codexRadar:\n            onCodexRadarRefresh()','        case .performance:\n            performanceViewModel.refreshNow()\n        case .skills:\n            skillInsights.analyzeRecentWeek()\n        case .codexRadar:\n            onCodexRadarRefresh()')
edit(path,'                        Text(page.title)\n                            .font(.system(size: 10, weight: .bold))','                        Text(page.title)\n                            .font(.system(size: 10, weight: .bold))\n                            .lineLimit(1).minimumScaleFactor(0.7)')
path='Sources/CodexNotch/AppDelegate.swift'
edit(path,'    private lazy var codexRadarViewModel = CodexRadarViewModel(settings: settings)','    private lazy var codexRadarViewModel = CodexRadarViewModel(settings: settings)\n    private lazy var performanceViewModel = PerformanceMonitorViewModel(settings: settings)\n    private lazy var skillInsights = SkillInsightsFeatureCoordinator(settings: settings)')
edit(path,'            codexRadarViewModel: codexRadarViewModel,\n            overlayState: overlayState,','            codexRadarViewModel: codexRadarViewModel,\n            performanceViewModel: performanceViewModel,\n            skillInsights: skillInsights,\n            overlayState: overlayState,')
edit(path,'    private static func visualQASnapshot() -> UsageSnapshot {','    static func visualQASnapshot() -> UsageSnapshot {')
for name,replacements in {
    'SkillInsightsPanelView': [('width: 148','width: 88'),('width: 42','width: 26'),('width: 24','width: 16'),('width: 44','width: 34')],
    'PerformancePanelView': [('width: 58','width: 40'),('width: 72','width: 48'),('width: 70','width: 48'),('width: 54','width: 50')]
}.items():
    f=S/f'{name}.swift'; text=f.read_text()
    for old,new in replacements: text=text.replace(old,new)
    f.write_text(text)
edit('Tests/CodexNotchRegressionTests/main.swift','0.1.17','0.2.0',3)

# 测试注入仅跳过真实数据读取，渲染的是生产页面。
path='Sources/CodexNotch/CodexRadarViewModel.swift'
edit(path,'        now: @escaping @MainActor () -> Date = Date.init','        now: @escaping @MainActor () -> Date = Date.init,\n        previewSnapshot: CodexRadarSnapshot? = nil')
edit(path,'        observedToken = settings.codexRadarAPIToken\n        observeSettings()','        observedToken = settings.codexRadarAPIToken\n        if let previewSnapshot { snapshot = previewSnapshot; return }\n        observeSettings()')
path='Sources/CodexNotch/PerformanceMonitorViewModel.swift'
edit(path,'    private let historyStore: PerformanceHistoryStore','    private let isPreview: Bool\n    private let historyStore: PerformanceHistoryStore')
edit(path,'        historyStore: PerformanceHistoryStore = .shared','        historyStore: PerformanceHistoryStore = .shared,\n        previewSamples: [PerformanceSample]? = nil')
edit(path,'        backgroundMonitoringEnabled = settings.performanceMonitoringEnabled','        isPreview = previewSamples != nil\n        backgroundMonitoringEnabled = settings.performanceMonitoringEnabled\n        if let previewSamples { samples = previewSamples; return }')
edit(path,'    func refreshNow() {\n        guard refreshTask == nil else {','    func refreshNow() {\n        guard !isPreview, refreshTask == nil else {')
path='Sources/CodexNotch/SkillInsightsViewModel.swift'
edit(path,'    private let service: SkillInsightsService','    private let isPreview: Bool\n    private let service: SkillInsightsService')
edit(path,'    init(service: SkillInsightsService = SkillInsightsService()) {\n        self.service = service\n        snapshot = .empty','    init(service: SkillInsightsService = SkillInsightsService(), previewSnapshot: SkillInsightsSnapshot? = nil) {\n        self.service = service\n        isPreview = previewSnapshot != nil\n        snapshot = previewSnapshot ?? .empty\n        if isPreview { return }')
edit(path,'    func refreshWhenPresented() {\n        guard !isAnalyzing else {','    func refreshWhenPresented() {\n        guard !isPreview, !isAnalyzing else {')
edit(path,'    private func runAnalysis(automatic: Bool) {\n        guard !isAnalyzing else {','    private func runAnalysis(automatic: Bool) {\n        guard !isPreview, !isAnalyzing else {')
edit(path,'    func shutdown() {\n        weeklyTimer?.invalidate()','    func shutdown() {\n        snapshotGeneration += 1\n        weeklyTimer?.invalidate()')
edit(path,'    var snapshot: SkillInsightsSnapshot { viewModel?.snapshot ?? .empty }','    init(previewSnapshot: SkillInsightsSnapshot) {\n        serviceFactory = { SkillInsightsViewModel(previewSnapshot: previewSnapshot) }\n        viewModel = serviceFactory()\n    }\n\n    var snapshot: SkillInsightsSnapshot { viewModel?.snapshot ?? .empty }')
for f in S.glob('*.swift'):
    text=f.read_text().replace('com.alight.codexnotch','dev.yzin.codexmonitor')
    text=text.replace('.appendingPathComponent("codex监测",','.appendingPathComponent("CodexMonitor",')
    text=text.replace('.appendingPathComponent("CodexNotch",','.appendingPathComponent("CodexMonitor",')
    f.write_text(text)
edit('Sources/CodexNotch/AppInfo.swift','static let version = "0.1.17"','static let version = "0.2.0"')
edit('scripts/build-app.sh','APP_NAME="codex监测"','APP_NAME="CodexMonitor"')
edit('scripts/build-app.sh','APP_VERSION="0.1.17"','APP_VERSION="0.2.0"')
edit('scripts/build-app.sh','BUNDLE_ID="com.alight.codexnotch"','BUNDLE_ID="dev.yzin.codexmonitor"')
edit('scripts/build-app.sh','  codesign --force --deep --sign - "$app_dir"','  codesign --force --deep --sign - "$app_dir"\n  codesign --verify --deep --strict "$app_dir"')
write('VERSION','0.2.0\n')
(root/'docs/upstream').mkdir(parents=True,exist_ok=True)
shutil.copy2(base/'README.md',root/'docs/upstream/ALight-README.md')
(root/'licenses').mkdir(exist_ok=True)
if own_license.startswith('MIT License'): write('licenses/Yzin-original-MIT.txt',own_license)
shutil.copy2(donor/'LICENSE',root/'licenses/Jackie-MIT.txt')
write('LICENSE','许可范围见 NOTICE.md 与 licenses/。此前独立实现版本的 MIT 不自动覆盖所有导入代码。ALight 固定快照未附单独 LICENSE；本次导入不替上游重新授予许可。\n')
write('NOTICE.md',f'''# 来源与许可范围

本版本直接基于 ALight777/codex-monitor 的原始源码，不是从零重写。

ALight 基线：{ALIGHT}，上游 v0.1.17，https://github.com/ALight777/codex-monitor 。
Jackie 扩展：{JACKIE}，https://github.com/jackiemingnew/codex-monitor-macos 。只移植性能、Skills 和必要依赖，不引入 WebKit 登录 Analytics。

逐文件来源和变更哈希见 docs/UPSTREAM_LOCK.json；ALight 原始 Git 历史作为导入提交的父历史保留。旧版独立实现保存在 archive/independent-before-alight-20260910；旧 UI 试验保存在 ui/compact-panel-20260910-01。

ALight 固定快照没有单独 LICENSE。Jackie 随附 MIT 文本（含 ALight777 与 Jackie Liu 署名）原样保存在 licenses/Jackie-MIT.txt；不据此替 ALight 后续改动作授权声明。原 yzin MIT 保存在 licenses/Yzin-original-MIT.txt。公开二次分发的授权范围仍需向对应权利人确认，不将上游代码声称为自己的独立作品。
''')
write('AGENTS.md','''# 项目开发规则

## 基线

以 ALight 原项目为基础，先保留原有 UI、交互、统计、Radar、远程账号和设置，再做明确要求的增量修改。不得再次从零重写或擅自删除功能。性能与 Skills 来自 Jackie，来源见 docs/UPSTREAM_LOCK.json。

## 文档与许可

新增说明性文档必须中文。上游原文和许可保留，遵守 NOTICE.md 的来源与许可边界，不宣称整个仓库为独立原创。

## 安全与验证

原始日志只读，不退出或重启 Codex，不注入 CDP。原版网络和凭据能力按开关使用，不新增上传对话或模型调用。只读不等于离线。安装不能关闭 Gatekeeper、移除 quarantine 或结束其他监控应用。测试只用合成数据和替身密钥库。

执行 scripts/test.sh、scripts/build.sh 及原生截图测试。检查 Codex、性能、Skills、Codex Radar 和远程开关。CI 编译、截图与真实账户对账是不同验收，不能互相冒充。
''')
write('SECURITY.md','''# 安全边界

0.2.0 改用 ALight 原始基线，不再声称整个应用完全离线或不使用凭据。

本地用量读日志，实时额度可使用官方 app-server。Radar 与自动价格更新请求公开服务；远程账号和余额按配置发送对应凭据。Radar 和远程源默认保持上游关闭状态；Radar 标签常驻，未启用时显示真实空状态。只看本地数据时可以选择仅本地记录，关闭价格自动更新及远程源。

性能读取本机 CPU/内存，后台采样默认关闭。Skills 使用本地目录、日志和本机 skills/list，不调用模型，不向第三方上传会话。证据等级不等于执行效果，关联对话 Token 不能当作 Skill Token。

凭据使用独立 Keychain 命名空间。保留上游数据库保存选项，但它不是加密保险库，建议保持 Keychain；不要随意跳过 TLS 校验。未导入 Jackie 的 ChatGPT WebKit 登录页。

安装保留系统保护，ad-hoc 签名未做 Apple 公证。不得在公开 Issue 中分享 auth.json、Cookie、密钥或完整会话。
''')
write('README.md','''# Codex Monitor

**以 ALight 原始项目为基线，保留原有 UI 和功能，增加 Jackie 的性能与 Skills。**

版本 0.2.0。旧版独立重写的 CodexMonitorCore/App 已从工作树移除，历史备份保留。这次不是给重写版补标签。

## 页面与功能

主标签固定为 **Codex / 性能 / Skills / Codex Radar**。远程账号、NewAPI、Sub2API 按原版设置开关显示，没有删除这些能力。Radar 标签可见不等于自动启用网络数据源。

保留原版刘海几何、标准/窄刘海、展开收起动画、会话表、Token 构成弹窗、子代理汇总、费用、价格更新、额度和重置次数、远程多源与设置。增加 Jackie 的 CPU/内存采样、低能耗调度、Skills 目录、证据分层、疑似漏触发/误触发、周报及 Markdown/JSON 导出。Skill 诊断是证据推断，不是效果保证；逐 Skill Token 不可得。

## 安装与开发

要求 macOS 14+、Swift 6。

```bash
git clone https://github.com/yzin-17/codex-monitor.git
cd codex-monitor
./scripts/install.sh
```

已有旧版时先退出本项目的 Codex Monitor，再执行 `./scripts/install.sh --replace`。安装到 `~/Applications/CodexMonitor.app`，原安装先备份，不结束 Codex 或参考监控应用。Bundle ID 是 `dev.yzin.codexmonitor`，凭据和派生目录独立。未做 Apple 公证，不要关闭系统保护。

```bash
./scripts/test.sh
./scripts/build.sh
```

原版入口 `scripts/build-app.sh` 与 `scripts/install-user-app.sh` 保留。上游详细说明在 [ALight README](docs/upstream/ALight-README.md)。另见 [来源锁定](docs/UPSTREAM_LOCK.json)、[许可范围](NOTICE.md)、[安全边界](SECURITY.md)、[验收记录](docs/VALIDATION.md)。

网络功能保留并按设置启用，不再宣称完全离线。性能后台采样默认关闭，Skills 可单独关闭；无新增网页登录或会话遥测。截图只使用合成数据，不代表真实账户、网络服务和实机交互已经验收。
''')
write('docs/VALIDATION.md','''# 0.2.0 基线纠正验收

日期：2026-09-10。ALight ec9363d 原始工作树加 Jackie 6cd6c00 的性能、Skills 和必要依赖。旧版 56/66 项测试只属于旧版，不证明此次通过。

本次由对应提交的 macOS CI 验证原版 Swift Testing、独立回归、新增扩展测试、真实 SwiftUI 四页截图、ARM64 与 Intel 编译打包和签名。结果以 Actions 为准，失败不得推进 main。

尚未验收：用户真实日志对账、实机拖动/交互、远程服务实连、Apple 公证。截图带合成数据标识。
''')
write('scripts/install-user-app.sh','''#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$ROOT_DIR/dist/CodexMonitor.app"
INSTALL_DIR="${CODEX_NOTCH_INSTALL_DIR:-$HOME/Applications}"
TARGET_APP="$INSTALL_DIR/CodexMonitor.app"
[[ "${1:-}" == "" || "${1:-}" == "--replace" ]] || { echo "用法：$0 [--replace]" >&2; exit 2; }
[[ -d "$SOURCE_APP" ]] || { echo "请先运行 scripts/build-app.sh" >&2; exit 1; }
if [[ -d "$TARGET_APP" && "${1:-}" != "--replace" ]]; then echo "已安装；请先退出 Codex Monitor，再用 --replace。" >&2; exit 1; fi
if /bin/ps -axo command= | /usr/bin/grep -F "$TARGET_APP/Contents/MacOS/" | /usr/bin/grep -v grep >/dev/null; then echo "请先退出此项目的 Codex Monitor。" >&2; exit 1; fi
mkdir -p "$INSTALL_DIR"
if [[ -e "$TARGET_APP" ]]; then mv "$TARGET_APP" "$TARGET_APP.backup-$(date +%Y%m%d-%H%M%S)"; fi
ditto "$SOURCE_APP" "$TARGET_APP"
codesign --verify --deep --strict "$TARGET_APP"
open "$TARGET_APP"
echo "已安装：$TARGET_APP"
''',True)
write('scripts/test.sh','#!/usr/bin/env bash\nset -euo pipefail\ncd "$(dirname "$0")/.."\npython3 scripts/verify-upstream.py\n./scripts/run-regression-tests.sh\n',True)
write('scripts/build.sh','#!/usr/bin/env bash\nset -euo pipefail\ncd "$(dirname "$0")/.."\npython3 scripts/verify-upstream.py\nexec ./scripts/build-app.sh\n',True)
write('scripts/install.sh','''#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${1:-}" == "" || "${1:-}" == "--replace" ]] || { echo "用法：$0 [--replace]" >&2; exit 2; }
./scripts/build.sh
exec ./scripts/install-user-app.sh "${1:-}"
''',True)
write('scripts/verify-upstream.py','''#!/usr/bin/env python3
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
''',True)
with (root/'.gitignore').open('a') as f: f.write('\n.baseline-output/\n*.jsonl\nauth.json\n.env\n*.sqlite*\n')
overlay=root/'tools/baseline-files'
if overlay.exists():
    for src in sorted(overlay.rglob('*')):
        if src.is_file():
            target=root/src.relative_to(overlay); target.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(src,target)
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
records=[]
for src in sorted(base.rglob('*')):
    if not src.is_file() or '.git' in src.relative_to(base).parts: continue
    rel=src.relative_to(base); target=root/'docs/upstream/ALight-README.md' if rel.as_posix()=='README.md' else root/rel
    if target.exists(): records.append(dict(path=target.relative_to(root).as_posix(),source='ALight',source_path=rel.as_posix(),source_sha256=digest(src),sha256=digest(target),modified=digest(src)!=digest(target)))
for name in DONORS:
    src=donor/'Sources/CodexNotch'/f'{name}.swift'; target=S/f'{name}.swift'
    records.append(dict(path=target.relative_to(root).as_posix(),source='Jackie',source_path=src.relative_to(donor).as_posix(),source_sha256=digest(src),sha256=digest(target),modified=digest(src)!=digest(target)))
write('docs/UPSTREAM_LOCK.json',json.dumps({'alight':ALIGHT,'jackie':JACKIE,'files':records},ensure_ascii=False,indent=2)+'\n')
print(f'已导入 ALight 原始项目；{len(DONORS)} 个 Jackie 扩展文件。')
