# 任务进度自动发现与自定义布局验收

日期：2026-11-20。基于 `v0.4.12`（`859f48f`）增量实现，功能分支为 `feat/task-progress-auto-discovery-hud-layout`。

## 实现范围

- 沿当前任务的精确会话记录增量发现 Markdown 清单，识别任务引用、创建、更新和读取过的文档，并扫描常见项目任务目录。
- 明确关联且实际含任务的文档尝试自动绑定；仅目录匹配或读取过的文档保留为候选。手动移除会持久排除，手动章节范围优先。
- Monitor 原生进度浮窗提供「清单／文档／设置」三个 tab，包含文档分组、未完成与已完成条目、原文及源位置、候选来源、章节搜索、草稿确认／取消、固定和移动。
- 自定义布局使用 AppKit 拖放，统一处理拖入、同行排序、跨行移动、移除及插入位置。移动保留账号绑定、空格尺寸和条件规则。
- 所有文字、数字布局组件按当前内容计算宽度，取消 Token 速度的最大文案预留。组件间距为 5 pt，隐藏组件不占位；手动空格、图标和用量条保留自身尺寸。

## 已实际通过

原生环境：Apple 芯片 Mac，macOS 27.2，Apple Swift 6.4.2。数据使用合成会话、临时 Markdown、独立偏好及替身密钥库。

| 验证 | 最终结果 |
| --- | --- |
| `scripts/test.sh` | 401 项 Swift Testing 测试、4 个 suite 通过 |
| 独立回归程序 | 输出 `All regression tests passed` |
| 原生截图测试 | 生成 32 张 PNG，包含原有 Codex、性能、Skills、Radar、远程与设置页面及本轮新界面 |
| ARM64 Release | 编译、DMG 打包和 ad-hoc 签名校验通过 |
| Intel x86_64 Release | 交叉编译、DMG 打包和 ad-hoc 签名校验通过 |
| 补丁格式检查 | `git diff --check` 通过 |

完整回归通过后以 `CODEX_NOTCH_SKIP_TESTS=1 scripts/build.sh` 执行双架构打包，避免同一源码重复跑完整测试。开发构建沿用仓库当前 `VERSION`，不代表新增了正式 tag 或 Release。

本轮新增并逐张检查的截图为：`task-progress-checklist.png`、`task-progress-documents.png`、`task-progress-settings.png`、`hud-native-layout-editor.png`、`hud-adaptive-width.png`。另检查了长标题任务行，状态文字与进度计数正常显示。新增截图由现有 CI 的原生截图测试生成并随产物上传；保持原有工作流配置。

## 重点回归覆盖

- 会话 ID 与继承历史隔离、增量读取、半行、日志截断／替换、符号链接及大小写路径去重。
- 明确引用和写入的自动绑定、缺失文件重试、只读候选、16 份绑定上限、禁用自动绑定、手动排除及恢复。
- 后续不同章节线索可扩大自动范围；手动范围保持。手动扫描无关目录或同一文档所在目录，不改变已有明确章节、进度分母或绑定 revision。
- 大量非任务 Markdown 后的有效清单仍可发现；并行会话游标不会因 32 条容量限制反复从头读取。
- 已绑定任务在面板关闭后继续更新，V1 存储兼容，保存前重读文档，后台 revision 冲突时保留草稿，保存期间禁止修改选择。
- 拖放数据的编辑会话、布局、修订与源位置校验；满行排序、新增上限、重复空格、条件规则及账号绑定保留。
- 空闲、`8.5`、`68.4`、`999.9 token/s` 的宽度逐级增加；相同位数保持数字等宽；其他文字和数字组件随实际内容伸缩。

## 真实鼠标交互：受环境权限阻塞，尚未验收

独立调试进程的系统检测实际返回 `CGPreflightPostEventAccess=false`。验证程序明确失败并停止输入，没有申请或修改系统权限。因此，拖入、排序、跨行、移除、取消，以及完整设置窗口切换 tab 后拖动保存这两组真实鼠标流程，均不能记为已经通过。

纯行为测试和截图不代替这项验收。这个权限用于自动模拟鼠标的验证程序；Monitor 的日常手动拖放使用 AppKit 原生事件。

在具备系统输入投递权限的 macOS 图形会话中，可分别复跑：

```bash
swift build -c debug
.build/debug/CodexNotch --qa-hud-interaction widgets
.build/debug/CodexNotch --qa-hud-interaction settings
```

每组必须看到对应 `PASS` 和 `HUD_NATIVE_QA PASS complete`，且退出码为 0，才算通过。该入口使用正常 AppKit 主循环、独立合成数据及 45 秒超时，并检查前台窗口与输入坐标；入口和测试窗口代码均只在 DEBUG 编译。

真实账户对账、长期运行、Intel 实机执行及 Apple 公证不在本轮已通过项目中。
