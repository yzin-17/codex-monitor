# 0.3.1 固定状态与布局验证

日期：2026-09-10。基于现有 0.3.0 / ALight 与 Jackie 扩展增量修改，没有替换原版主界面和统计实现。

## 本地验证

Linux 隔离测试工程编译实际 HUDLayoutModel、HUDDisplayData，15 项核心测试全部通过；修改的 Swift 文件语法解析以及构建/回归脚本语法检查通过。没有运行源码或补丁哈希检查。

## macOS 实际验证

[固定运行状态与原版配色验证 #1](https://github.com/yzin-17/codex-monitor/actions/runs/34487933767) 的 validate 和 publish 作业均成功。验证源码提交为 `9b7df80cbfdf88311a82640af563a5223170e48e`，功能分支已发布该提交。

| 验证项 | 实际结果 |
| --- | --- |
| Swift Testing | 165 项通过：既有 148 项 + 本次 17 项；0 失败 |
| 原版独立回归程序 | All regression tests passed |
| ARM64 Release | 编译、打包与 ad-hoc 签名校验通过 |
| Intel x86_64 Release | 交叉编译、打包与 ad-hoc 签名校验通过；未在 Intel 实机运行 |
| 原生界面 | Codex、性能、Skills、Codex Radar、对话费用、Codex 账号、菜单栏 HUD、布局编辑器、固定左侧状态、右侧清空共 10 张截图生成并检查 |
| 固定左侧状态 | 自定义区域不包含 state；清空右侧仍显示状态灯及 RUN；远程来源不替换本机运行状态 |
| 布局 | 重复空格独立移动、删除及调整宽度；布局迁移、条件控件、无数据与过期状态均有测试 |
| 配色 | 恢复 MonitorTheme 语义色和中性黑底；无 NSVisualEffectView 壁纸染色材质；保留用户自定义透明度并迁移旧默认值 |
| 安装包 | 生成 codex-monitor-0.3.1-arm64.dmg 和 codex-monitor-0.3.1-amd64.dmg |

构建日志仍含旧费用测试中未使用返回值的警告，不将测试通过描述为零警告。截图和账户测试只用合成数据及内存凭据库，不代表真实账户数据。

正式发布提交仅更新本验证记录、任务状态、常规 CI 截图清单并移除一次性传输工作流，不修改经过上述 macOS 验证的生产源码。main 上的常规重复构建以对应提交的 GitHub Actions 为准。

## 仍需实机验收

真实账户数据、左右分区点击/拖动、物理刘海中心对齐、多屏切换和连续动画手感仍需真实 Mac 验收。Intel 尚未做实机运行；安装包未做 Apple 公证，不应关闭系统安全保护。
