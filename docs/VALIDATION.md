# 验证记录

日期：2026-09-10

## 本次实际环境

Linux x86_64；Swift 6.2.1；系统 SQLite 3.46.1。

## 实际执行

| 验证 | 结果 |
| --- | --- |
| `swift build --product codex-monitor` | 通过 |
| `swift test` | 56 项 XCTest 通过，0 失败 |
| `swift run codex-monitor --demo --format json` | 通过，输出明确标记 demo |
| `scripts/check-offline.sh` | 通过：未发现网络／WebView／运行时子进程 API |
| GUI 源文件 `swiftc -frontend -parse` | 通过，仅语法，不是 macOS 类型检查 |
| Bash 脚本语法检查 | 通过 |

测试使用临时目录和合成 JSONL／SQLite，不使用真实账户文件。覆盖累计差分、缓存与推理不重复计数、重复事件、基线、回退、跨期、父子与循环、Fork、半行、重写、超长行、只读源校验、私有缓存权限、缓存不保存正文、暖缓存不重写、Skill 证据与同名消歧、未知价格和报告脱敏。

## 未在本次环境完成

macOS SwiftUI/AppKit 类型检查、`.app` 构建与签名执行、安装和窗口交互、真实 Codex 最新日志适配、桌面深链接、真实账户数据对账、百万行性能和网络抓包。

提供了 macOS CI 与构建脚本，**没有**声称已经执行。不要把此交付视为经过 Mac 实机验收的正式发行包。

## Mac 上的验收路径

1. `./scripts/test.sh`：必须通过核心回归与静态门禁。
2. `./scripts/build.sh`：必须通过 macOS 编译、生成 .app 与 codesign 校验。
3. `./scripts/install.sh`：明确安装到独立应用路径，不影响 Codex 与参考项目。
4. 打开演示模式核对四个页面、菜单栏、浮动条、深浅色和窗口缩放。
5. 退出演示模式，选择真实数据目录，逐轮回填后抽样对账。
6. 原始 Codex 文件内容前后比较；检查本应用缓存未包含 Prompt 或工具正文。
7. 在任务表核对父 Token、子 Token、合计和分模型；在 Skill 页核对一次失败读取不被算成成功。

失败时保留编译器错误、脱敏事件类型与字段结构。不得把 auth.json 或完整会话直接附到公开 Issue。

## codex-monitor 改名与发布准备验证（历史记录）

日期：2026-09-10。此源码包从先前 Agent Ledger 首版统一改名而来；以下是当时尚未写入 GitHub 的准备阶段结果，不代表后续仓库导入状态。

| 验证 | 结果 |
| --- | --- |
| 改名后的 `./scripts/test.sh` | 56 项核心测试通过；演示 CLI、离线门禁、GUI 语法解析通过 |
| `swift build -c release --product codex-monitor` | Linux Release 编译通过 |
| 全部 Bash 脚本 `bash -n` | 通过 |
| 发布脚本模拟测试 | 9 项通过；使用真实本地 Git，GitHub API 与网络 push 均为替身 |
| GitHub 创建仓库与实际推送 | 未执行：会话只有 GitHub 读取接口，没有 GitHub CLI 登录 |
| GitHub Actions／macOS 桌面构建 | 未执行；不将语法解析当成类型检查 |

发布脚本测试覆盖：必须选择可见性、拒绝错误账号、拒绝覆盖远程已有内容、拒绝更改可见性、只提交清单文件、需要时浏览器授权、推送失败不报成功、提交校验失败不报成功、相同提交重复执行不再 push。

复测：`python3 Tests/PublishingTests/test_publish.py`。日志见 `docs/validation/publish-script-smoke.log`。源码包不包含 `.build`、账号文件、真实会话或 `.git` 凭据。

## 仓库导入前复测

日期：2026-09-10。用户已创建 `yzin-17/codex-monitor`，初始 `main` 为 `22018eb8d5dc4d129dfb4bfa043a423c8e5ddc48`。导入保留原始 MIT 许可证和初始提交，仅新增项目文件；修正了侧栏漏改的旧项目名称。

解压原始源码包后，重新执行 `./scripts/test.sh`，56 项核心测试通过；`python3 Tests/PublishingTests/test_publish.py` 的 9 项模拟测试通过。全量 Git 文件树与本地发布清单应在更新分支前进行校验。

macOS CI 的执行结果以该提交对应的 GitHub Actions 为准；推送成功、CI 构建成功和真实桌面交互验收是三个独立状态。
