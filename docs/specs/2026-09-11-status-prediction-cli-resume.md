# 官方状态、独立重置预测与 CLI 续跑

日期：2026-09-11。基于已验证的 0.3.2 增量交付，不另建 UI/统计引擎。

## 边界

保留原黑色 HUD、固定左侧状态、右侧自定义、原字号、面板原位展开、六项交互修复及全部原有功能。主标签增加“重置预测”；公共信息与账号信息、任务执行互相隔离。不实现任何邮件协议，仅跳转 Will 网站订阅。

## 公共信息

性能页读取 https://status.openai.com/api/v2/summary.json，分别显示总体状态和可识别 Codex/登录组件。最后状态变更时间不当作本次获取时间。未识别组件显示未知。

预测页独立读取 https://codex.gussuriworks.com/api/current?locale=zh 和 https://www.willcodexquotareset.com/api/forecast。前者概率按明确的 0～1 比例转换；后者须确认 horizonHours=48，按 0～100 分值展示。calibrated=false 时标记未校准。没有值不填 0；两个来源不合并。固定 URL、HTTPS、无重定向、无 Cookie、无凭据、最大 2 MiB、有限超时、各自开关和缓存。每五分钟刷新；断线或上游 stale 标记保留旧数据并提示。

Will 邮件提示固定为“订阅与退订由网站管理，本工具不读取邮箱或接收邮件通知”，按钮仅使用系统浏览器打开网站，不假定订阅成功。

## CLI 续跑

逐对话显式开启；可在耗尽前处于 armed，明确额度错误后处于 waiting。前置读取真实本机会话设置及官方 thread/read、thread/turns/list（旧版受限回退 thread/read includeTurns），只接受最后一轮 failed + UsageLimitExceeded，不按正文猜测。额外读取原始 JSONL 头和有限尾段，只提取会话 ID、提供商、工作目录、模型、推理强度、沙盒和审批。目录遍历与读取有预算。

核对本机文件型 ChatGPT CLI 身份，验证官方额度，再复查失败回合、原目录、权限、模型与活跃状态。仅在耗尽之后取得的新鲜官方额度确认所有已知阻塞窗口恢复时发送；线程完成/被人工继续/中断、账号和配置改变均不继续。默认 read-only，workspace-write 需用户同意且原任务允许，不添加外网或额外可写根目录，不放宽审批。

发送通过精确会话 ID 的 codex exec resume，用户文案通过 stdin，不拼接 Shell。不使用 --last、CDP、模拟键盘、--yolo、账号轮换、自动兑换次数。CLI 原始输出不保存，解析启动/回合完成状态。单次等待分发后变 finished 或 attention，不循环重试。

持久等待状态、应用私有锁和执行前独占收据降低重复发送；跨 Desktop/CLI 的竞争没有原子接口保障，必须在 UI 告知勿同时操作。恢复后仅发起新回合，不宣称模型内部执行点恢复或 Desktop 窗口自动同步。

## 验收

解析与状态机使用合成数据；CLI 使用替身真实进程覆盖参数、stdin、只读 RPC 与取消。macOS 全量测试、原版回归、所有原生标签和配置截图、ARM64/Intel 打包。真实登录、多显示器、Desktop/CLI 同步单独保留人工验收。源码/补丁不进行哈希检查。
