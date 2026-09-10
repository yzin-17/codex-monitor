# Codex Monitor

一个独立实现的 **macOS 原生 Codex 用量与 Skills 证据分析工具**。

首版 `0.1.0`。主要界面为中文，采用 SwiftUI / AppKit；统计核心可在 Linux 测试。

> **交付状态**：已有统计核心、命令行、桌面界面源码、浮动条、测试与构建脚本，不是空项目模板。56 项核心测试在 Linux / Swift 6.2.1 通过；macOS GUI 目前仅完成 Swift 语法解析，尚未在真实 Mac 上编译或验收。此源码包不包含已经验证的 `.app` / DMG。详见 [验证记录](docs/VALIDATION.md)。

## 你能用它做什么

- 看每个任务的 **父对话、全部已识别子代理、合计**，以及分模型 Token。
- 查看今日、近 7 天、近 30 天、累计的已观察用量；缓存输入和推理输出不重复累加。
- 从 `sessions` 和 `archived_sessions` 增量扫描 JSONL；存在回填、损坏行或无法归属的基线时明确提示。
- 读取本地 `state_*.sqlite` 中的标题和父子关系；数据库不可用时保留日志内可识别信息。
- 发现用户／项目的 Skills，查看明确提及、简单读取尝试、配对成功返回、关联对话和证据偏移。
- 使用菜单栏或可拖动浮动条查看汇总；点击对话可通过 `codex://` 跳转，不自动发送消息。
- 导出隐藏标题、路径与原始会话 ID 的 Markdown / JSON 报告。
- 导入本地价格表做单档参考估算；未知费率不猜价。

它**不是** ALight 与 Jackie 的整仓合并，不包含它们的源文件。现有项目仅作为功能需求参考，新代码采用独立模块边界。

## 隐私默认值

**不提供网页登录，不收集 API Key，不调用模型，不启动 Codex 子进程，不请求第三方服务。**

本程序默认不访问 `auth.json`、Cookie 或 Keychain；只读允许的日志、索引和 Skill 文件。原始 Prompt、助手回答、工具输出不会写入派生缓存。缓存仍含会话 ID、模型、Skill 路径、用量、证据偏移，不能随意公开。源 SQLite 使用只读连接与查询事务；系统 SQLite 的 WAL/SHM 行为仍由 SQLite 和 macOS 管理。

网络与子进程 API 有静态回归门禁，不代表这份代码获得了安全认证。应用未启用 macOS App Sandbox，运行时仍需信任所构建的版本。详见 [安全边界](SECURITY.md)。

## 源码仓库

仓库：[yzin-17/codex-monitor](https://github.com/yzin-17/codex-monitor)。应用名和模块已经统一为 Codex Monitor / CodexMonitor；Bundle ID 使用独立的 `dev.yzin.codexmonitor`。

本仓库已初始化，日常开发使用普通 Git 分支与提交，不要再运行首次创建仓库脚本。`scripts/publish-github.sh` 保留用于原始源码包的空仓库发布，并会拒绝覆盖已有不同历史。详细边界见 [发布说明](docs/PUBLISHING.md)。源码发布不等于发布了经过 Mac 实机验收的安装包。

## 在 Mac 安装

要求 macOS 14+，以及带 **Swift 6** 的 Xcode / Command Line Tools。打开终端，克隆仓库后执行（已经解压源码时直接进入对应目录）：

```bash
git clone https://github.com/yzin-17/codex-monitor.git
cd codex-monitor
./scripts/install.sh
```

脚本先测试，再构建当前 Mac 架构的应用，安装到：

```text
~/Applications/CodexMonitor.app
```

已存在应用时默认拒绝覆盖。先退出 **Codex Monitor** 再明确替换：

```bash
./scripts/install.sh --replace
```

旧版会备份，不会结束或重启 Codex / ChatGPT，不修改它们的 Bundle，不开启 CDP，也不会移除 quarantine 或关闭 Gatekeeper。应用使用本地 ad-hoc 签名，未做 Apple 公证。

只构建、不安装：

```bash
./scripts/build.sh
```

输出 `.app` 和可移交给同架构 Mac 的 ZIP，位置是 `dist/`。跨机器运行仍需遵守 macOS 安全提示；不要下载来源不明的二进制。

### 第一次打开

1. 在 **设置与隐私 → 数据目录** 选择真实的 Codex 数据目录。默认是 `~/.codex`；自定义目录可直接选择。
2. 点 **刷新 / 继续回填**。单轮默认最多读取约 32 MiB 日志、处理约 2 秒；大型历史需多轮。自动刷新默认关闭，可以主动打开。
3. 在 **添加项目** 中选择实际工作目录，再进入 Skills。插件目录需手动添加其真实 Skills 根目录，不把缓存存在误判成已启用。

没有日志时可开启演示模式；演示界面始终标注“演示数据”。退出演示后恢复真实读取。

### 功能边界必须知道

| 项目 | 当前口径 |
| --- | --- |
| 桌面当前选中的对话 | 不自动识别；应用列出本机对话，由你选择 |
| 账户额度 | 仅展示日志中的额度快照与记录时间，不是实时查询；历史百分比不会在到点后伪造为已恢复 |
| Skills 启用状态 | 文件系统发现默认 **未知**；可导入已有 `skills/list` JSON 快照，状态仅代表导入时 |
| Skill 成功 | 读取命令返回成功不等于实际遵循 Skill，更不等于提高质量 |
| 逐 Skill Token | 不支持，不能把关联会话的总 Token 归因给 Skill |
| 目录 Token | 名称、描述和路径字符数 / 4 的粗估，不是 tokenizer 精确值或账单 |
| 费用 | 导入用户核实的单档价格后才估算；未知模型、历史基线、超出 `maxInput` 的请求排除 |
| 回测／精确省钱归因 | 不根据一次关联判断 Skill 或委派是否省钱 |
| 自动漏触发／误触发 | 首版没有可靠分类器，不提供假精确评分或自动删除建议 |

## 项目结构

```text
Sources/
  CodexMonitorCore/       用量、父子关系、JSONL 增量、Skills、报告与价格
  CodexMonitorApp/        macOS 主窗口、菜单栏、可拖动浮动条、设置
  CodexMonitorCLI/        无界面本地分析与演示输出
  CSQLite/              系统 SQLite 桥接，无外部包依赖
Tests/                  脱敏合成数据测试，不读取你的真实账号
scripts/                测试、离线检查、构建、安装、卸载
examples/               演示价格表与 skills/list 格式示例
.github/workflows/      macOS CI，实际执行状态以 GitHub Actions 为准
```

统计核心与 GUI 分开，后续可按模块定制，不需要把整个应用写进一个大文件。

## 本地开发与测试

```bash
./scripts/test.sh
swift run codex-monitor --demo
swift run codex-monitor --home ~/.codex --project /你的项目 --format json --passes 50
```

Linux 可以编译、测试核心及 CLI，不能构建 SwiftUI / AppKit 应用。Linux 需要系统 SQLite 开发头文件。

CLI 默认不写缓存；`--passes` 是此次进程内继续回填的轮数。界面版使用本应用的私有派生缓存。所有导出仍应在分享前人工检查。

### 本地价格与目录快照

`examples/prices.example.json` 只有虚构的 demo 模型费率。**不能把示例金额作为 Sol / Luna 的真实价格。** 修改为精确模型名和核实的费率后，在设置中导入。

`examples/skills-list.example.json` 展示已有 `skills/list` 响应的兼容格式。导入不是必需，本项目不自动执行这个 RPC，也不会为了获取它启动或重启 Codex。当前不完全解析所有 YAML / TOML 语法，不把全局文件扫描说成完整生效目录。

## 卸载

从菜单栏退出 Codex Monitor，再运行：

```bash
./scripts/uninstall.sh --confirm
```

卸载仅移除 `~/Applications/CodexMonitor.app`，保留本应用设置与派生缓存，不改 Codex 数据。缓存目录是 `~/Library/Application Support/CodexMonitor`，需要清除时请先核对路径再操作。

## 后续开发顺序

先在 Mac 完成编译和真实日志兼容验证，再扩展“按项目的权威 Skill 目录”“真实任务级费用”“Skill 诊断建议”。每项独立交付，不把原生 GUI、解析器、状态机和真实环境验收塞进同一个任务。

参见 [规格](docs/specs/2026-09-10-codex-monitor-v0.1.md)、[任务](docs/tasks/2026-09-10-codex-monitor-v0.1.md)、[数据口径](docs/DATA_CONTRACT.md)。

## 参考

协议与功能语义参考 OpenAI 的公开文档；这些参考不是对本程序兼容性或安全性的背书。

- [Codex App Server](https://developers.openai.com/codex/app-server/)
- [Skills](https://developers.openai.com/codex/skills/)
- [桌面深链接](https://developers.openai.com/codex/app/commands/)

本项目不隶属于 OpenAI，不是官方插件或监控工具。
