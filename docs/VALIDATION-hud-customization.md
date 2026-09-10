# 0.3.0 验证记录

日期：2026-09-10。以现有 0.2.1 / ALight 原始基线及 Jackie 扩展增量修改。

## 已完成的 macOS 验证

[菜单栏浮窗与 Codex 账号验证 #4](https://github.com/yzin-17/codex-monitor/actions/runs/34473968808) 的 validate 与 publish 作业均成功，最初验证实现为 a2d87eb。主体发布 45272d3 的 [main CI](https://github.com/yzin-17/codex-monitor/actions/runs/34475031904) 也已成功。

随后在原生截图中发现双行 HUD 的固有内容尺寸可能将窗口从 22 pt 撑到 24 pt，已固定视图高度并关闭 HUD/下拉窗口 hosting view 的反向尺寸约束。[菜单栏浮窗高度回归 #2](https://github.com/yzin-17/codex-monitor/actions/runs/34476099486) 在 b0ed4dd 实现上再次完成全量验证及分支发布。最终发布使用该已验证生产源码，仅移除临时工作流并更新本记录。

实际环境：macOS 15.7.9 ARM64、Apple Swift 6.1.2。

| 验证项 | 结果 |
| --- | --- |
| Swift Testing | 最终 148 项通过：既有 123 项 + 新增 25 项 |
| 原版独立回归 | All regression tests passed |
| ARM64 Release | 编译、打包与 ad-hoc 签名校验通过 |
| Intel x86_64 | 交叉编译、打包与 ad-hoc 签名校验通过，未在 Intel 实机运行 |
| 原生截图 | Codex、性能、Skills、Codex Radar、对话费用、菜单栏浮窗、布局编辑器、Codex 账号共 8 张生成成功并检查 |
| 原生 HUD 高度 | 双行截图为 220 × 22；新增实际 NSHostingView/NSWindow 高度断言，几何测试覆盖 20/22/24/32 pt 菜单栏及负坐标副屏 |
| 揭露动画基础 | HUD 起始裁剪区域、正文原字号及最终尺寸不随裁剪缩放的行为测试通过 |
| 账号验证 | 使用替身 HTTP/内存凭据库验证固定只读端点、导入限制、401 不保存、工作区隔离、取消与迟到结果、Keychain 保存失败与账户删除 |
| 源码哈希 | 检查脚本和 test/build 调用已移除，未运行源码或补丁哈希检查 |

修复了 SwiftUI 的 Binding.animation 同名绑定歧义、账号属性初始化顺序、紧凑模式中额度重置条与标题的间距。HUD 高度上限从预留内边距调整为 min(22, 菜单栏高度) 后，同步旧几何测试的精确断言并补齐多种菜单栏高度；保留边界断言和新增原生窗口断言，没有跳过失败测试。

常规 CI 从 VERSION 读取安装包版本，不再写死旧版本号。最终 main 提交的重复构建以 GitHub Actions 对应提交为准。

## 功能边界

非刘海模式仍为覆盖式 NSPanel，不使用 NSStatusItem。面板从 HUD 下缘向外、向下揭露，收回原位，内容只裁剪不缩放；面板目标仍为 680 × 720。背景透明度单独设置，文字不随之变淡。

新增直连账户只有 Codex，保留原有网关/NewAPI/Sub2API。用户选择 auth.json 或填写 Access Token 后，必须实际验证官方额度接口成功才保存新凭据；不保存 Refresh Token，不改写 Codex 登录文件，不实现自动 OAuth 续期。

截图和测试仅使用合成数据与替身凭据。CI 验证的是正确发起、处理与取消验证的逻辑，不证明用户真实账号已认证。

## 仍需实机验收

真实账号接口、菜单栏覆盖与遮挡、连续展开收起动画的手感、快速反向点击、睡眠、多显示器切换和长期资源占用仍需实机确认。静态截图不证明动画流畅度。安装包未做 Apple 公证，不应关闭系统安全保护。
