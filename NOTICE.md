# 来源与许可范围

本版本直接基于 ALight777/codex-monitor 的原始源码，不是从零重写。

ALight 基线：ec9363d56a3692903f5ccb7462df2a0fbafc7297，上游 v0.1.17，https://github.com/ALight777/codex-monitor 。
Jackie 扩展：6cd6c00aa7327a79a8b4256cf8ec2573375832f3，https://github.com/jackiemingnew/codex-monitor-macos 。只移植性能、Skills 和必要依赖，不引入 WebKit 登录 Analytics。

逐文件来源和变更哈希见 docs/UPSTREAM_LOCK.json；ALight 原始 Git 历史作为导入提交的父历史保留。旧版独立实现保存在 archive/independent-before-alight-20260910；旧 UI 试验保存在 ui/compact-panel-20260910-01。

ALight 固定快照没有单独 LICENSE。Jackie 随附 MIT 文本（含 ALight777 与 Jackie Liu 署名）原样保存在 licenses/Jackie-MIT.txt；不据此替 ALight 后续改动作授权声明。原 yzin MIT 保存在 licenses/Yzin-original-MIT.txt。公开二次分发的授权范围仍需向对应权利人确认，不将上游代码声称为自己的独立作品。

0.3.1 的 HUD 控件类型与交互参考 steipete/CodexBar（固定快照 7fdc17636f161ab410d8a6a0e8f45b6a595cf8d2）的 MenuBarLayoutToken；实现按本项目数据模型适配，没有接入其供应商或复制其整套运行时。

0.4.0 的服务状态呈现参考 steipete/CodexBar 的公开状态页思路；续跑状态机参考 JiaYang-BUAA/Codex-Desktop-Usage-Monitor-Windows 的 auto-resume.mjs / desktop-request.mjs，但发送改为用户选择的本机 CLI，不复制 CDP 注入和硬编码 approvalPolicy。社区预测来自 gussuri/codex-reset-observatory 的公开 API 及 www.willcodexquotareset.com 的网页实际使用的公开 forecast API；后者并非承诺稳定的第三方 API。只提供邮件订阅网页入口，不实现订阅服务。新增 Swift 适配为本项目实现，原上游归属与许可边界不变。
