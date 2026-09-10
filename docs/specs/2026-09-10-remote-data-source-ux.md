# 远程数据源与 HUD 交互修复

日期：2026-09-10。目标版本：0.3.2。基于 0.3.1 的 ALight 原版与 Jackie 扩展增量修改。

## 范围

修复远程来源控件的黑字、浮窗实际高度、指标文字基线、网页登录缺失、重复远程入口、透明度语义及滑块对齐、重置次数最近到期提示。不改 Token 统计、代理费用、Skills、性能、Radar、原有网关请求协议与存储。

## 数据源统一

设置及详情仅保留一个远程账号入口，内部按四类数据源查看或新增：

| 类型 | 凭据和数据含义 |
| --- | --- |
| Codex 官方账号 | 官方网页登录或显式导入；该账号订阅额度与 credits |
| 网关上游账号 | CLIProxyAPI、CPA Manager Plus、Sub2API 管理端；管理密钥读取上游 Codex 账号池和额度 |
| NewAPI 用户余额 | 站点 PAT；用户余额与站点用量，非 ChatGPT 订阅额度 |
| Sub2API 用户余额 | 当前用户的站点余额；与同一产品管理端账号池是两个权限范围 |

使用现有配置键和凭据库，不跨类型复用密钥，不合并币种或额度，不在升级时开启旧的关闭数据源。保留旧页面枚举以兼容已保存选择，展示时映射至统一页。数据源类型按钮显式使用 MonitorTheme 深色语义色。

## 网页授权

浏览器体验参考 CodexBar；协议使用 Codex 官方 app-server 的 initialize、account/login/start（chatgpt）、account/login/completed 与 account/login/cancel。协议说明：https://developers.openai.com/codex/app-server。

本应用仅启动自己创建的 Codex 子进程，使用独立临时 CODEX_HOME（0700）和 file 凭据存储覆盖。该目录不会读取用户 ~/.codex/config.toml 或改写当前登录；过滤继承的 API Key。OAuth/PKCE 与 localhost 回调由官方 CLI 处理。本应用只接受官方 HTTPS 授权地址及 localhost 回调，打开系统浏览器，不读 Cookie、不拦截密码。匹配 loginId 的成功通知后读取受限的临时 auth.json，并复用既有官方额度校验，校验成功再保存 Access Token。

最长等待五分钟，取消、浏览器失败、协议错误和超时都结束本次子进程并删除临时文件。CLI 可能临时写入 Refresh Token；本应用不把它复制到持久凭据库。默认 Codex Desktop 未安装或 CLI 不可用时明确失败并提供已有高级导入，不偷偷换成网页登录抓 Cookie。外部工具或系统崩溃造成的异常清理不宣称绝对保证。

## 外观

菜单栏高度读取当前屏幕 frame/visibleFrame 的顶部差，自动隐藏时回退系统菜单栏尺寸。浮窗顶边与屏幕顶边一致，高度占满菜单栏，不通过放大字号填满。标签与数值使用 firstTextBaseline；固定状态不参与右侧排序。

透明度以 1-opacity 读写：0% 不透明，HUD 最高 100%、正文面板最高 65%；保留旧值。位置、HUD 和面板滑块使用一致的 150 pt 标签列、弹性轨道、44 pt 百分比列。

重置次数中的日期来自 reset credits 的 expiresAt，因此显示“最近到期”，而不是把它命名为自动额度恢复。只选未来日期；缺少日期显示未知，零次不展示虚构倒计时。窄行保留原有紧凑布局，宽面板展示完整倒计时。

## 验收

合成协议进程测试覆盖浏览器打开、匹配登录、隔离目录、取消、失败清理；现有请求/Keychain 测试继续执行。几何覆盖多个菜单栏高度与负坐标副屏；透明度持久化、最近到期选择均需回归。运行全部 macOS 测试、原版独立回归、双架构编译与原生截图。真实账号登录和多屏覆盖另行实机验收，不冒充 CI 完成。
