# Codex Monitor

**以 ALight 原始项目为基线，保留原有 UI 和功能，增加 Jackie 的性能与 Skills。**

版本 0.3.1。旧版独立重写的 CodexMonitorCore/App 已从工作树移除，历史备份保留。这次不是给重写版补标签。

## 页面与功能

主标签固定为 **Codex / 性能 / Skills / Codex Radar**。远程账号、NewAPI、Sub2API 按原版设置开关显示，没有删除这些能力。Radar 标签可见不等于自动启用网络数据源。

保留原版刘海几何、标准/窄刘海、展开收起动画、会话表、Token 构成弹窗、子代理汇总、费用、价格更新、额度和重置次数、远程多源与设置。增加 Jackie 的 CPU/内存采样、低能耗调度、Skills 目录、证据分层、疑似漏触发/误触发、周报及 Markdown/JSON 导出。Skill 诊断是证据推断，不是效果保证；逐 Skill Token 不可得。

## 0.3.1：固定状态与原版配色

左侧固定显示本机 Codex 状态灯和 RUN/IDLE，右侧才应用自定义布局。显示模式与刘海几何合并；HUD 与下拉面板恢复中性黑底和 MonitorTheme 的灰/白/绿额度语义色，不使用壁纸染色材质。字号和从 HUD 展开的动画保持。

布局新增可重复的空格（可调整宽度）、分隔点、范围/直接额度、节奏、明确窗口的重置控件、预计用尽及条件显示。旧布局会自动移除右侧 state 条目；可以清空右侧而保留左侧运行状态。数据源不支持的控件显示 —，不会新增 Codex 以外的供应商。详见 [规格](docs/specs/2026-09-10-fixed-status-layout-style.md) 和 [验证记录](docs/VALIDATION-fixed-status.md)。

## 0.3.0：紧凑浮窗与 Codex 账号

面板保持 680 × 720 逻辑点目标尺寸，**字号恢复 1.0 倍**，用更多空间展示内容，而不是整体放大字体。

设置 → 启动与外观：自动 / 刘海屏 HUD / 非刘海屏菜单栏浮窗。非刘海仍是覆盖菜单栏的 NSPanel，无刘海占位，默认最大宽度 220 pt，高度限制在菜单栏内，可调整横向位置。不是 NSStatusItem。支持内容预设、添加/移除、拖动排序、两行布局、按来源覆盖与示例预览。透明度只作用于背景；面板从 HUD 下缘向外、向下展开，收回 HUD，文字不缩放。

设置 → 远程账号：保留原网关配置，新增 **Codex 账号** 验证。手动提供 Access Token 或显式选择 auth.json 导入，再点击“验证并保存”。只有官方额度接口验证成功后才保存到本应用 Keychain；不存 Refresh Token、不改 Codex 当前登录。支持多个命名账号、单独启停/刷新、堆叠展示及绑定 HUD。过期后重新登录 Codex 并导入。**不额外接入 Codex 以外的提供商。**

验证改为编译、回归、行为测试和原生截图，不执行源码哈希检查。来源和许可记录保留。

详见 [本次规格](docs/specs/2026-09-10-hud-layout-provider-accounts.md)、[验证记录](docs/VALIDATION-hud-customization.md)。

## 0.2.1 增量

展开面板目标 680 × 720 逻辑点，随屏幕可用区域限制大小，内容和字号同步放大；紧凑刘海不变。点击对话标题展开主代理、各子代理及任务合计，右侧 Token 构成弹窗独立保留。Skills 开启时显示可配对成功读取的“Skill 关联回合费用”，不是独占费用或订阅扣款，不可与任务合计再次相加。明细按需在后台分片读取，超出预算可继续扫描；收起或切页取消。

详见 [增量规格](docs/specs/2026-09-10-expanded-panel-cost-details.md) 和 [验证记录](docs/VALIDATION-panel-costs.md)。

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
