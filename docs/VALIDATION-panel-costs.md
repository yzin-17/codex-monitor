# 展开面板与对话费用验证

日期：2026-09-10。应用版本：0.2.1。基线：`54c7cfab87587ab808ea5f48b75faede880c6182`。

## 修改范围

沿用当前 ALight + Jackie 实现。新增展开面板几何、代理用量累计器、只读按需加载器、行内明细界面；接入原版详情视图、应用窗口尺寸和同一数据目录。四主标签、远程功能、Token 构成弹窗、紧凑刘海保持。原始价格表和原始 Token 快照算法没有替换。

## 已执行的本地验证

Linux / Swift 6.2.1 隔离测试工程内，27 项布局、费用与只读加载测试通过。测试使用产品源码 ExpandedPanelLayout、ConversationCostDetails、ConversationCostLoader 和未改的 TokenCostEstimator、CodexSessionEventDecoder。仅在临时工程将 SkillJSONLReader 的 Darwin 引入改成 Glibc，并替换资源采样和 autoreleasepool 的平台适配；这些替身没有进入产品代码。

覆盖：大/小屏及负坐标副屏、累计去重、缓存/推理子集、计数回退及缺口、未知价格、逐请求长上下文定价、Skill 配对成功/失败/关闭/无回合、同名目录、关联重叠、父子孙/Fork、归档副本、继承边界、半行续扫、截断、取消、符号链接和分片续扫。

所有 Swift 源文件语法解析及来源文件哈希门禁通过。语法解析不等于 macOS 编译。

## 已执行的 macOS 验证

[放大面板与代理费用验证 #2 的 validate 作业](https://github.com/yzin-17/codex-monitor/actions/runs/34462438644/job/102823143853) 已成功。验证源码提交为 `93125169d3b5a4ab48e664837546cff9fbce8c97`，源码树为 `da6eb68874cdbe49f083cc5da0ac3283e73c4274`。

| 项目 | 实际结果 |
| --- | --- |
| Swift Testing | 123 项通过，包含既有 96 项与新增 27 项 |
| 原版独立回归程序 | All regression tests passed |
| ARM64 Release | 编译、打包、ad-hoc 签名校验通过 |
| Intel x86_64 Release | 交叉编译、打包、ad-hoc 签名校验通过；未在 Intel 实机执行 |
| 原生窗口截图 | Codex、性能、Skills、Codex Radar、conversation-costs 五张生成成功；费用展开截图已检查 |
| 安装包 | codex-monitor-0.2.1-arm64.dmg 和 codex-monitor-0.2.1-amd64.dmg |
| 源码完整性 | 20 个修改文件的 SHA256 与本地实现逐个匹配，最终源码树不包含一次性传输文件 |

首次构建中 123 项 Swift Testing 已通过，但原版独立回归有两处断言仍写死为 0.2.0；已同步到 0.2.1 并完整重跑成功，没有删除测试或跳过失败断言。来源清单仅更新对应已评审文件的哈希，保留原始来源哈希。

上述结论针对 macOS validate 作业，不代表同次流程的发布作业成功。发布作业因 GitHub Actions 自带凭据缺少工作流写权限被拒绝；源码提交、分支更新与常规 main CI 必须分别核验。最终发布提交只补充这份验证记录及任务状态，生产源码与已验证源码树一致。

截图和测试仅使用合成数据，没有提供真实账户凭据。main 的重复构建结果以对应提交的 GitHub Actions 为准。

## 仍需真实环境验收

用户的真实日志、主/子代理对账、Skill 回合关联抽样、刘海/外屏点击与拖动、弹窗焦点和长期性能；Intel 实机执行与 Apple 公证。Skill 费用为关联回合参考，不是独占的 Skill 账单；多个 Skill 可能重叠，不再次计入任务合计。
