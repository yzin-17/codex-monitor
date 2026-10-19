# CodexRadar 刷新修复验收

验收时间：2026-09-07，Asia/Shanghai。

> 下方原验收记录保留其历史口径。2026-10-20 的当前实现与接口核查见本文末节及[当前规格](../../docs/specs/2026-10-20-radar-community-scores.md)。

## 根因证据

- 本机原缓存与实时读取的 `https://codexradar.com/current.json` 内容一致；旧摘要 `model_iq.updated_at` 为 `2026-09-06T15:06:03+08:00`，说明刷新请求成功但旧数据源未跟随官网众测更新。
- 官网页面当前从 `https://codexradar.com/api/intelligence-efficiency-metrics` 读取软件工程评分，手动刷新使用 `?refresh=1`。该接口返回当天数据、schema 3、DeepSWE 基准及 GPT-6 Astra。
- 原界面把本次拉取时间混入数据更新时间，原调度失败后直接等待下一个每日时点，且失败的手动请求也消耗 5 分钟冷却期。

## 修复结果

- 无 Token 时使用官网公开众测接口；有 Token 时保持授权 API 路径和现有密钥存储。
- 旧缓存首次启动立即迁移，显示全部 Codex 模型档位；平均成本、平均耗时及样本数按新接口含义显示。旧摘要的预测和套餐额度不混入当前众测评分。
- 每小时及北京时间 08:20、14:20 检查；失败保留最后有效数据并在 5 分钟后重试。手动成功后冷却 5 分钟，失败可以立即重试。
- 数据时间与最近检查分开显示。关闭功能或更换 Token 后取消旧请求，避免旧响应写回缓存。磁盘缓存失败也保留刚获取的有效界面数据。

## 验证

- `./scripts/run-regression-tests.sh`：65 项 Swift 测试通过，独立回归程序输出 `All regression tests passed`。包括真实 Timer 自动触发、迁移、手动失败重试、缓存保留、磁盘失败和取消后的迟到响应。
- `CODEX_NOTCH_SKIP_TESTS=1 ./scripts/build-app.sh`：arm64 与 amd64 Release 和 DMG 构建成功；跳过的是上一步已经通过的重复测试。
- 独立 Swift 程序使用实际客户端访问公开接口：25 个 Codex 档位，包含 GPT-6 Astra。
- 安装后应用自动把磁盘缓存迁移到 `publicMetrics`；原始数据源时间 `2026-09-07T13:57:36+00:00`。
- 通过实际应用 UI 点击 Radar 刷新按钮，最近检查从 22:03 更新到 22:04，磁盘记录为 `2026-09-07T22:04:18.663170`。此请求上游分数和测评时间未变，界面正确保持数据时间。
- 实际 UI 已显示 GPT-6 Astra ultra / max / high 等评分及平均费用、耗时。设置页显示最近检查 22:04、下次检查 23:04。
- 已验证应用签名与构建/安装二进制哈希一致。未等待自然一小时周期；自动触发已由真实 Timer 回归覆盖。

## 标签修正

官网众测的“状态”标签已改为“评测维度”，值为“软件工程”。arm64/amd64 重新构建并安装，实机截图和可访问性文本均确认显示正确。

本机安装回执、二进制哈希和回退路径仅保留在忽略的 `dist/qa/radar-refresh/` 下。

## 0.1.16 发布构建

- `./scripts/build-app.sh` 完整执行：65 项 Swift 测试和独立回归均通过，两份 Release DMG 构建成功。
- 两份 DMG 的镜像完整性、包内 0.1.16 版本号、对应架构和签名均通过校验。去除签名并规范化签名影响的链接段虚拟大小后，包内可执行代码与构建输出一致。
- 本机已安装 0.1.16，应用启动成功，安装与构建 app 的可执行文件 SHA-256 一致。

| 安装包 | SHA-256 |
| --- | --- |
| codex-monitor-0.1.16-arm64.dmg | `a4c43cb917d9e3853acb147c879f79a652a8efe5c201292c1bbe992406cc5470` |
| codex-monitor-0.1.16-amd64.dmg | `b4b946c0d809c04e3a092b61e52a821964b7af72e4bf664c406cb979ad910ab0` |

## 2026-10-20：检查时间、当前雷达与社区体感

### 官网公开接口核查

- 本机软件工程缓存最后成功获取于 10 月 5 日 13:50，视觉缓存最后成功获取于 10 月 9 日 09:03；新闻仍在 10 月 20 日更新。当前旧评分接口分别返回 HTTP 502，不据此断言此前整个期间均为同一故障。
- 首页主榜加载 `/assets/radar-bench-ui.mjs?v=bench-detail-metrics-v2`，由 `/assets/radar-bench-display.mjs?v=bench-detail-metrics-v1` 读取公开绑定和评分摘要。旧软件工程接口仍出现在另一处预览逻辑，旧视觉接口未出现在首页。
- 无凭据 GET `/data/radar-bench-binding.json` 返回 HTTP 200，当前基准为 `radar-bench-final64-20261004`，覆盖四个来源共 64 题。这里只核对接口语义，不执行源码或补丁哈希检查。
- 无凭据 GET `/api/radar-bench-score?model=gpt-6.1-sol&effort=low&view=summary` 返回 HTTP 200，响应 schema 为 `radar-bench-public-summary-v6-150-details`、满分 150，包含官网总分、四维分数与覆盖率。这是一个模型档位的公开读取证据，不代表全部档位可用。
- 无凭据 GET `/api/model-ratings` 返回 HTTP 200，响应为近 24 小时的 10 分制投票均分与票数。未提交投票，未携带 Cookie 或账户凭据。

### 实现与验证边界

- 最近检查与成功获取时间分离；失败也更新检查时间，取消或关闭后的旧结果不写回。综合页保留具体错误，旧基准缓存明确标识。
- 当前雷达分直接使用新契约，按模型档位独立保留缓存；社区体感分独立读取、缓存和报错。卡片精确关联模型与推理档位，按任一分数排序，缺失排后。
- 社区每 5 分钟读取一次，不因此重复请求尚未过期的全榜雷达；雷达请求并发最多 3 个，仅访问固定公开端点。
- 首轮刷新诊断定向测试 26 项通过，随后新评分解析与公开端点边界测试 4 项通过。新卡片集成首轮发现缓存标记改变后旧断言仍要求卡片整体不变，已改为检查分数、覆盖和数据时间不变，并单独断言缓存标记。
- 完整测试：`CODEX_MONITOR_SNAPSHOT_DIR=/tmp/codex-radar-20261020-screenshots scripts/test.sh` 通过，306 项 Swift 测试及独立回归程序全部通过。命令日志位于 `/tmp/codex-radar-20261020-tests.log`。
- 原生截图：已人工检查 Codex、性能、Skills、远程功能关闭时的回退页，以及雷达同卡评分、社区排序、HTTP 502 与旧缓存。截图位于 `/tmp/codex-radar-20261020-screenshots/`；README 示例已更新为 `docs/screenshots/radar-tab.png`，其中模型和分数均为合成数据。
- 构建：`CODEX_NOTCH_SKIP_TESTS=1 scripts/build.sh` 通过，arm64 与 amd64 Release 编译、应用签名校验及 DMG 打包均完成。跳过的是上一项已通过的重复测试。日志位于 `/tmp/codex-radar-20261020-build.log`；产物为 `dist/codex-monitor-0.4.8-arm64.dmg`、`dist/codex-monitor-0.4.8-amd64.dmg` 和 `dist/CodexMonitor.app`。
- 最终一致性复核：代码、AC1–AC6、任务、README 与验收记录一致，`git diff --check` 通过。在线证据限定为上文的公开接口读取，本地完整测试使用合成输入；未宣称完成所有真实模型档位的在线对账。
- 本轮不安装、不提交、不推送，不修改真实缓存或账户数据。原生截图使用合成数据和替身网络；真实账号对账、发布及已安装应用验收不由这些结果代替。

### 排序控件样式复核

- 排序入口统一为面板内的深色按钮样式：10 点灰色文字、28 点高度、7 点圆角、细描边及右侧小箭头。使用按钮式原生菜单保留完整标签样式，排序逻辑与选中状态沿用现有实现。
- 本轮 `scripts/test.sh` 的 306 项 Swift 测试及独立回归通过，日志为 `/tmp/codex-radar-menu-20261020-tests.log`。最终菜单样式另行通过原生页面测试，日志为 `/tmp/codex-radar-menu-20261020-native.log`；不重复执行未受样式影响的业务回归。
- 已人工检查雷达分排序、社区体感分排序两张最终原生截图。截图目录为 `/tmp/codex-radar-menu-20261020-screenshots/`，README 图片已同步为最终样式。
- 最终样式的 `CODEX_NOTCH_SKIP_TESTS=1 scripts/build.sh` 已通过，arm64、amd64 编译、签名校验及 DMG 打包完成，日志为 `/tmp/codex-radar-menu-20261020-build.log`。未安装、提交或推送。

### 0.4.9 发布授权与证据边界

上述记录是功能实施阶段的验收快照。用户随后授权更新版本、提交推送、从 GitHub 下载最新发布包并替换本地应用。版本声明同步更新 `VERSION`、`AppInfo.version`、README 徽章和独立回归断言；`main` 推送后的 CI、发布记录及安装回执与本地测试分开保留。

0.4.9 的本地 `CODEX_MONITOR_SNAPSHOT_DIR=/tmp/codex-monitor-049-screenshots scripts/test.sh` 通过，306 项 Swift 测试及独立回归全部通过；日志为 `/tmp/codex-monitor-049-tests.log`。功能与最终菜单样式的双架构构建记录见上文；0.4.9 安装包由发布 CI 重新构建。

发布记录：[Codex Monitor 0.4.9](https://github.com/yzin-17/codex-monitor/releases/tag/v0.4.9)。本机下载、替换与启动回执保留在忽略目录 `dist/qa/release-0.4.9/`，不把一次性安装材料提交到主分支。

### 0.4.10：非默认档位请求前置条件

0.4.9 安装启动后的首轮实际读取取得 1 个默认档位，另外 33 个档位均返回 HTTP 428；社区接口成功写入 43 个配置。该结果没有被当作全榜读取通过。

官网 `radar-bench-display.mjs` 对显式模型档位读取设置 `X-Radar-Bench-Selection: user-selected-v1`；应用实现漏传该标记。对 `gpt-6-astra/low` 的无凭据 GET 补齐该标记后返回 HTTP 200、当前 schema 及有效分数，确认是请求前置条件遗漏。

0.4.10 仅向固定雷达摘要端点补齐该请求头，测试替身模拟缺少标记时 HTTP 428，不携带账户凭据。版本声明与回归断言同步升级；本地验证和后续 CI 结果分别记录。

用户在 0.4.9 的实际菜单中确认选项被放入子菜单；0.4.10 将菜单项改为直接显示“雷达分”和“社区体感分”，当前选项保留勾选标记，排序与持久化逻辑沿用既有实现。

0.4.10 的 `scripts/test.sh` 通过：306 项 Swift 测试与独立回归全部通过，日志 `/tmp/codex-monitor-0410-tests.log`。随后直接菜单的原生界面与请求头前置条件替身补验通过，日志 `/tmp/codex-monitor-0410-native.log`，截图 `/tmp/codex-monitor-0410-screenshots/`；README 示例已同步。

独立只读诊断直接使用当前 `CodexRadarClient`、当前绑定和生产解析器，通过无凭据 GET 实际读取官网配置：34 个绑定档位全部读取并解析成功，错误数为 0。日志 `/tmp/codex-monitor-0410-live-probe.log`。该在线结果与合成数据回归分开记录，不代表真实账户对账或未来数据一直可用。

最终 0.4.10 的 `CODEX_NOTCH_SKIP_TESTS=1 scripts/build.sh` 通过，双架构编译、应用签名校验和 DMG 打包完成，日志 `/tmp/codex-monitor-0410-build.log`。最终一致性复核通过；发布 CI 和安装回执分别保留于 GitHub 与忽略目录 `dist/qa/release-0.4.10/`。
