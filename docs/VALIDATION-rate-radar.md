# 最近请求测速与 Radar 验收记录

日期：2026-11-22。对应 [规格](specs/2026-11-22-rate-radar.md) 与 [任务](tasks/rate-radar.md)。目标版本 `0.4.16`。

## 原因与修复

测速的真实日志含有效请求用量；此前工具等待过滤与 15 秒新鲜度判断叠加，把最近速度统一显示为占位。本次保留活动会话及子代理的最近请求值，等待或过期时置灰；无样本保留占位，空闲时隐藏。新鲜并发速度合计沿用原口径，历史样本只取最近一次。新增其他会话、未来、非有限及负数样本隔离回归，条件组件仍只采用新鲜数值。

Radar 公开接口在本轮读取时返回 HTTP 200、完整 58 个配置、232／232 项评分，但发布标识为 `codex-four-accepted-event/1`。旧实现仅接受 `codex-four-accepted-complete/1`，因此显示无效响应并保留旧缓存。本次只兼容这两个已知标识，其他完整性检查保留。

## 定向回归

`swift test --filter 'tokenRate|tokenSpeed|radarFourTask|CodexRadarCurrentRoundLifecycle'`：41 项、1 个 suite 通过。测试全部使用合成数据与替身传输。覆盖当前会话最近值、并发、等待和过期、无样本与空闲、未知发布标识、不完整总榜、缓存保留与新标识恢复。

## 公开源读取

只对已启用固定公开地址 `https://codexradar.com/data/codex-four-task-results.json` 发起无凭据 GET。响应保存在本机临时目录，不提交生产数据。使用生产解码器只读解析该响应，得到 `round=codex-four-repeat-oauth-20261121 models=58 state=ready`。这是公开接口兼容证据，与合成回归分开记录。

本轮证据目录为 `/tmp/codex-monitor-0.4.16/`，包括 `targeted.log`、`radar-live-decode.log`、公开响应及安装前缓存摘要。

## 完整门禁与交付

`CODEX_MONITOR_SNAPSHOT_DIR=/tmp/codex-monitor-0.4.16/ui-full scripts/test.sh` 完成 413 项测试、4 个 suite 与独立回归，全部通过。日志为 `test.log`。`CODEX_NOTCH_SKIP_TESTS=1 scripts/build.sh` 完成 ARM64／Intel Release 编译、DMG 打包及脚本内 ad-hoc 签名校验，日志为 `build.log`。`git diff --check` 通过。

已查看原生截图 `hud-token-rate-visibility.png`、`radar-combined-scores.png` 和 `radar-refresh-failure.png`：运行中有样本、等待工具及过期时保留对应速度，只有无样本为占位；空闲隐藏。Radar 使用新发布标识的合成快照显示已更新，失败快照继续保留缓存和恢复提示。原有主要页面与远程开关由完整回归覆盖。这些截图与测试均使用合成数据。

安装脚本已在 `/Applications/CodexMonitor.app` 原位置更新为 `0.4.16`。安装版本、bundle ID、签名和新进程核对通过；旧版 `0.4.15` 已退出，本次安装产生的备份已删除，剩余安装备份为零。安装记录为 `install.json`，原设置及绑定存储保持原位置。

安装前运行环境缓存为 `codex-four-377-all-native-20261119`，发布标识为旧的 `accepted-complete/1`；安装后的新应用自动刷新并保存 `codex-four-repeat-oauth-20261121`、58 个配置、`codex-four-accepted-event/1`，缓存修改时间与获取时间均已更新。摘要分别为 `radar-cache-before.json`、`radar-cache-after.json`。这是实际运行应用的成功解码和缓存更新证据，与只读公开源诊断及合成回归分别保留。

## 一致性审查与边界

本轮本地修复、公开源兼容和本机安装启动验收通过。已核对样本归属、新鲜与最近测量的区分、未知／不完整发布拒绝、缓存保留、源地址及授权写集。计数和耗时算法未改变，没有新增模型调用或凭据读取路径。版本入口同步为 `0.4.16`，本轮改动按用户授权合并提交并推送 `main` 与 `v0.4.16`；最终提交及 tag 以 Git 引用为准。

真实 HUD 视觉与账户对账没有由合成截图证明；CI 与安装后的长期运行结果独立报告。既有账户测试首轮失败与复验证据仍保留在原验收记录中。
