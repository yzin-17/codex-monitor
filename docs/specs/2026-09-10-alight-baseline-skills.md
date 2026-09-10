# ALight 原版复刻与 Skills 增量规格

日期：2026-09-10

## 目标

基于 ALight777/codex-monitor v0.1.17 的实际源码、资源、交互和功能进行定制。不是从零重画，不用此前独立实现的侧栏主窗口替代原版。先恢复原版可运行基线，再按明确需求增量接入 Skills。

## 保留原版

完整保留刘海 HUD、窄刘海模式、展开收起动效、深色面板、页面切换、刷新与设置、对话列表、父子代理统计、Token 构成、API 等价成本、当前费率、实时/本地额度来源、Radar 与各远程来源。原版源码与用户截图所处版本可能不同；以 UPSTREAM.md 的固定源码为可复现基准，实机视觉差异单独验收，不能凭编译结果宣称逐像素一致。

## Skills 增量

在原 DetailPanelView 新增 Skills Tab，在原设置新增 Skills 分类。保持原版字体密度、卡片和深色样式，不新建另一套主窗口。目录与证据解析使用隔离的 CodexMonitorCore；原版 CodexUsageStore、成本和额度计算不接入该核心。

支持本地目录发现、用户手动添加项目/额外根目录、已有 skills/list 快照导入、7/30 天证据范围、搜索、明确指定/助手声明/读取尝试/配对成功返回、关联对话跳转和脱敏导出。未知生效状态明确显示，不将读取成功视为有效执行，不将关联对话 Token 当作 Skill Token。

分析只手动触发，每轮预算约 32 MiB 和 2 秒；打开页面不扫描完整历史。取消或关闭后不回写迟到结果；无数据和部分回填必须明确标注。派生缓存不保存原始 Prompt、回答或工具正文。

## 安装和身份

目标应用为 ~/Applications/CodexMonitor.app，独立 Bundle ID dev.yzin.codexmonitor.alight。原版 Keychain service 与本地派生目录隔离；不自动迁移原版密码。替换本仓库旧版需 --replace 且先正常退出，备份旧应用；不得 pkill Codex/ChatGPT、移除 quarantine 或关闭 Gatekeeper。

## 验收

原版 tracked 文件逐一核验：除文档、身份隔离、Skills 导航和打包最小修复外不改动。原版 86 项 Swift Testing 与独立回归保留；Core 56 项测试及 Skills 适配测试分别执行。macOS 编译、双架构打包、签名检查和实机 UI 分开记录。真实账号对账和视觉确认不以合成数据替代。

## 非目标

本次不删除原版网络、远程账户或 Radar，不新增 ChatGPT 内嵌网页登录，不改统计口径，不合并 Jackie 整仓，不声称已经完成 Skills 漏触发自动诊断。安全裁剪是基线验收后的独立任务。
