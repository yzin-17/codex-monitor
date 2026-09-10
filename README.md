# Codex Monitor

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
