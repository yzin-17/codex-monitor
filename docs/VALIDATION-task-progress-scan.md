# 任务清单扫描修复验收

日期：2026-11-21。范围对应 [规格](specs/2026-11-21-task-progress-scan.md) 与 [当前任务](tasks/task-progress-scan.md)。证据基于当前未提交工作区，全部会话、Markdown、偏好和密钥库使用合成或隔离数据。

## 行为与实现

- `TaskProgressIndicator` 统一任务行的加载动画、未关联清单图标和已知进度圆环。浮窗空状态与文档页复用扫描状态；日志读取比例以已读取字节／总字节计算，分段结束但未追平时显示「待续读」。已有任务计数在后台扫描时保留。
- `TaskProgressStore` 在后台比较日志、候选文档与已遍历任务目录的文件身份、字节数、精确修改时间和权限。输入未变化且日志已追平时不重新读取、解析或发布扫描状态；5 秒轮询保留为变化检测与绑定文档同步的兜底。
- 目录发现返回实际观察过的目录和 Markdown 路径，覆盖嵌套目录新增、无任务文档后来新增任务、缺失引用文件恢复。变化触发后刷新目录发现缓存；手动重扫不受版本比较限制。
- 日志仍按原有预算分段读取，每次最多推进 8 块。仅未读日志触发后续分段，目录数量或时间上限不会造成自动无限续扫。停止后清除扫描标记，保留代际检查与取消保护。

## 测试

日志目录：`/tmp/codex-monitor-task-scan-20261121/`。

- 定向命令：`swift test --filter 'taskDiscovery|taskAutoBinding|taskProgressLabels'`，28 项通过。日志为 `targeted.log`。
- 完整命令：`CODEX_MONITOR_SNAPSHOT_DIR=/tmp/codex-monitor-task-scan-20261121/ui scripts/test.sh`，407 项测试、4 个 suite 通过，独立程序输出 `All regression tests passed`。日志为 `test.log`。
- 收尾审查补充了手动目录扫描与无变化检查交错结束时的扫描标记清理。最终源码执行 `swift test --filter 'taskDiscovery|taskAutoBinding|taskDirectoryScan|taskProgressLabels'`，30 项通过，日志为 `final-targeted.log`。完整 407 项与截图在这次局部清理前执行；该修改未改变界面源码，受影响调度通过定向回归复验，未重复整套回归。
- 新增回归覆盖：历史扫描完成后重复请求及重新打开保持原扫描时间；追加日志后自动绑定；嵌套任务目录新增文件；缺失文件恢复；同字节数文件更新；跨过真实 5 秒轮询及无关事件仍保持空闲；未变更的大日志继续推进；停止清除扫描标记；各状态文案与部分数据不显示总百分比。
- 原有完整回归覆盖设置持久化、远程来源默认关闭、自动绑定排除、手动范围、候选来源及文档同步。未启用真实远程来源或使用真实账户。
- 编译日志保留了既有费用测试未使用返回值、CLI 测试捕获变量等警告；测试通过不等于零警告。

## 原生截图

同一完整回归生成 36 张 PNG，位于 `/tmp/codex-monitor-task-scan-20261121/ui/`。

已逐张查看：`task-progress-states.png`、`task-progress-unbound-checklist.png`、`task-progress-unbound-documents.png`、`task-progress-unbound-settings.png`、`task-progress-checklist.png`、`task-progress-documents.png`、`task-progress-settings.png`、`task-row-long-title.png`，以及 `codex.png`、`performance.png`、`skills.png`、`codexRadar.png`、`remoteCodex.png`。

状态示例能区分加载、未关联、分段续读与已有进度；清单三个页签内容完整，长标题行的计数正常显示。远程来源关闭时 `remoteCodex` 入口回落到本机页面，符合现有截图替身配置；此截图不证明真实远程连接。CI 新增四个截图文件存在性检查，保留原有页面门禁。

## 构建

首轮 `CODEX_NOTCH_SKIP_TESTS=1 scripts/build.sh` 成功，日志为 `build.log`。收尾清理后对最终源码再次执行同一命令，成功退出，日志为 `final-build.log`。两个架构均完成 Release 编译、DMG 打包及脚本内 ad-hoc 签名校验：

- `dist/codex-monitor-0.4.13-arm64.dmg`
- `dist/codex-monitor-0.4.13-amd64.dmg`
- `dist/CodexMonitor.app`（本机 ARM64 版本）

开发产物沿用仓库版本号，不代表已创建正式 Release。`git diff --check` 通过。

## 一致性审查

通过本轮本地实施与合成验证范围：AC1—AC4 的实现、回归、截图与构建证据一致；核对了空状态、未读日志续跑、目录上限、元数据比较、强制重扫、停止取消和并发状态清理。只修改任务清单实现、相应测试、正常 CI 截图清单及中文说明，未改变账户、网络或原有权限策略。当前没有阻塞本轮范围的问题。

## 本地修复阶段的验收边界

初次修复验收时未安装、重启或发布应用，未创建提交。原始日志保持只读。已安装版本的真实会话表现、真实账户对账、长期运行与 Intel 实机执行没有由本轮合成测试或截图证明。

## 用户授权的版本交付

后续测速修改完成后，最终功能源码已通过 409 项完整复验，详见 [布局与测速验收记录](VALIDATION-task-progress-layout.md)。用户明确授权将这几轮改动一起提交、推送 tag 并安装本机；交付版本为 `0.4.14`。

同步 `VERSION`、`AppInfo.version`、README 版本标识及独立回归中的版本断言。复用上述完整功能回归，仅重新编译、执行回归脚本的独立程序段，并执行 `CODEX_NOTCH_SKIP_TESTS=1 scripts/build.sh`。独立程序、ARM64／Intel 编译打包和签名校验均通过。日志位于 `/tmp/codex-monitor-release-0.4.14/`。

通过仓库安装脚本在 `/Applications/CodexMonitor.app` 原位置替换，原应用保留为带时间戳的备份；安装版本与 bundle ID 核对通过，签名校验通过，已检测到新启动的本项目进程。安装记录为同目录的 `install.json`。本次只退出并重新打开本项目的 Monitor，设置及任务绑定保持原存储位置，Codex 及其他监控应用未被退出。

本机安装与启动成功不代替用户对真实任务清单、测速和账户的最终验收。
