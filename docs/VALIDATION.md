# 0.2.0 基线纠正验收

日期：2026-09-10。

## 实际源码来源

以 ALight `ec9363d56a3692903f5ccb7462df2a0fbafc7297`（v0.1.17）的原始工作树为基线，移植 Jackie `6cd6c00aa7327a79a8b4256cf8ec2573375832f3` 的 18 个性能/Skills 文件及必要适配。旧独立重写的 Sources/CodexMonitorCore 和 Sources/CodexMonitorApp 不再存在，保留在备份分支。

源码纠正提交：[`b89aefd`](https://github.com/yzin-17/codex-monitor/commit/b89aefd19d5598578d7c2fa1a0f92f12b5da88f1)。该提交同时继承本仓库历史和 ALight 原始 Git 历史。逐文件来源与差异哈希见 UPSTREAM_LOCK.json；原版资源、测试与业务逻辑没有被自写占位功能替代。

## 已实际通过

验证工作流：[纠正为 ALight 原始基线 #3](https://github.com/yzin-17/codex-monitor/actions/runs/34452535635)。该流程先在只读权限的 macOS 任务导入并验证源码树，再由不执行上游代码的发布任务快进纠正分支。

实际环境：macOS 15.7.9 ARM64、Apple Swift 6.1.2。

| 验证 | 结果 |
| --- | --- |
| 来源与功能门禁 | 91 个来源文件哈希匹配，旧重写模块不存在，四主页面与远程内容均接线 |
| Swift Testing | 96 项通过：原版 86 项 + 扩展 10 项 |
| 原版独立回归程序 | 输出 All regression tests passed |
| ARM64 Release | 原始应用与移植模块编译、打包、ad-hoc 签名校验通过 |
| Intel x86_64 Release | 交叉编译、打包、ad-hoc 签名校验通过；未在 Intel 实机执行 |
| 四页原生截图 | Codex、性能、Skills、Codex Radar 都通过真实 NSWindow/NSHostingView 捕获；已逐张检查滚动区实际内容 |
| 安装包 | 生成 codex-monitor-0.2.0-arm64.dmg 与 codex-monitor-0.2.0-amd64.dmg |
| 分支发布 | 验证后的提交已推送至 fix/alight-baseline-20260910；main 发布以该提交在 main 的可达性为准 |

截图只有合成数据，包含明确标识；不把演示模型评分、余额或用量当作真实账户结果。验证期间没有提供真实账号凭据。

## 本次修复的问题

移植时适配 ALight 原本已只读的 SQLite API；修复干净目录缺少 dist 时的打包失败；不再每次构建改写受版本控制的上游图标；隔离模型价格缓存目录。ImageRenderer 会遗漏 AppKit 滚动内容，因此验收改为挂载真实窗口再捕获，而不是接受空白截图。

## 仍需实机验收

用户真实日志/父子用量抽样对账、窗口拖动与点击全流程、长期性能、睡眠恢复、远程服务实连、Intel 实机运行和 Apple 公证。编译、截图成功不等于上述项目已经完成。

本次收尾提交只更新验证文档、任务状态与 CI 产物保存，移除一次性导入工作流，不修改已验证的生产 Swift 源码。后续 main 的常规 CI 结果以 GitHub Actions 对应提交为准。
