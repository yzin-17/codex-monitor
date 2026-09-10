# 紧凑浮窗、自定义内容与 Codex 账号验证

日期：2026-09-10。基线：0.2.1，目标：0.3.0。

## 本次范围

继续使用 ALight 原版面板与 Jackie 的性能/Skills。展开面板保持 680 × 720 目标尺寸，取消 1.4 倍缩放，字号、行高和按钮保持原始尺寸。主代理、子代理、Skill 关联回合费用与四主页面继续保留。

## 屏幕外观与动画

自动、刘海、非刘海三种模式。非刘海仍使用覆盖菜单栏的 borderless/nonactivating NSPanel，层级高于 statusBar；不是 NSStatusItem。HUD 按内容收紧，默认最大宽度 220 pt，实际高度最多 22 pt，且不超过系统菜单栏高度。无中间刘海留白；横向位置可调整，避开菜单栏已有按钮，适配负坐标外屏。

详情面板位于 HUD 下层，顶边与 HUD 重叠 2 pt。展开从 HUD 宽度和 2 pt 高度出发，同时拓宽并向下揭露；收起按相反路径回到 HUD。正文一直保持最终尺寸，通过居中、顶部固定的裁剪容器显示，不缩放文字。连续快速开关用 generation 令牌丢弃过时 completion；减少动态效果或选择立即动画时不执行形变。

HUD/面板分别调节背景浓度，文字不透明度不变，使用 NSVisualEffectView 背景；尊重降低透明度设置。

## 自定义展示内容

参考 CodexBar 的行/指标结构：最多两行，每行六项，支持预设、点击添加/移除、拖动排序、按来源覆盖、示例预览。可显示图标、来源、账户、状态、额度、用量条、今日 Token、重置时间、余额、费用。未知值显示 —，不混用账户或凭空推算。已有网关和余额页面不删除。

## Codex 账号验证

不新增 Claude、OpenRouter、DeepSeek、Moonshot 或其他提供商。新增入口只接受 Codex OAuth Access Token，或由用户显式选择 auth.json 一次性导入。仅提取 access_token/account_id，不保留 refresh_token/id_token，不自动扫描浏览器或其他应用，不切换/改写 Codex 登录。

验证必须向固定的 https://chatgpt.com/backend-api/wham/usage 发起带 Bearer 的 GET；用户选择工作区时设置 ChatGPT-Account-Id。接口返回成功且能解析额度/credits 才允许保存到本应用 Keychain。仅解码 JWT 或读取文件不代表验证成功。401/403、非预期数据、账户不匹配或取消时不保存新凭据；已有账户网络失败保留旧值并标注。

可添加多个命名账号、逐一验证/启停/刷新、选择或堆叠展示、绑定 HUD。凭据与结果按 UUID、工作区、revision 隔离。最大并发 3，默认 5 分钟刷新，默认关闭后台监测。替换工作区须提供新凭据，取消或删除后丢弃迟到结果。只保存经过验证的 Access Token，不自动兑换/轮换 Refresh Token；过期后由用户重新登录并导入。

网络只访问上述固定 HTTPS 端点，不跟随重定向、不带 Cookie、不设置磁盘响应缓存，不用 URL 查询参数传 Token；响应最多 1 MiB，导入文件最多 256 KiB。订阅额度与 credits 不是美元或本地估算费用。无真实账号的 CI 不能证明上游实连。

## 验证方式

移除源码哈希检查脚本及 test/build/CI 中的调用，来源清单仅保留仓库版本与路径。正常编译、行为测试、回归、原生窗口截图和代码评审继续执行；不把签名校验或合成截图说成真实账户验收。

参考：CodexBar 的 MenuBarLayout / Editor 布局思路与 docs/codex.md 账户隔离、官方额度请求；Jackie 的玻璃背景与既有窗口结构。只按实际复用标记来源，不宣称完整移植 CodexBar 登录流程。
