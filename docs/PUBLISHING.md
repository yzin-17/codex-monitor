# 发布到 GitHub

> 仓库已由用户创建并初始化。此文的首次发布脚本说明仅适用于原始源码包与空仓库，不用于向已有不同历史的仓库导入或覆盖。日常修改应在克隆后的仓库中正常提交、推送。

## 仓库与身份

首次发布目标为 `yzin-17/codex-monitor`。应用显示名称是 **Codex Monitor**，可执行程序和模块前缀为 `CodexMonitor`，Bundle ID 为 `dev.yzin.codexmonitor`。安装路径为 `~/Applications/CodexMonitor.app`，派生数据目录为 `~/Library/Application Support/CodexMonitor`。

这些标识不与 ALight/Jackie 的 `com.alight.codexnotch` 或 `codex监测.app` 共用，也不自动迁移旧 Agent Ledger 的配置。

## 在 Mac 首次发布

准备 Swift 6、Git 和 GitHub CLI。GitHub CLI 缺失时可先安装：

```bash
brew install gh
```

在源码根目录执行其中一种方式，必须明确选择可见性：

```bash
./scripts/publish-github.sh --public
# 或仅自己可见：./scripts/publish-github.sh --private
```

脚本在需要时启动 GitHub 浏览器授权，并校验 CLI 账号必须是 `yzin-17`。不需要把 Token 粘贴到聊天或源码。GitHub CLI 负责保存授权；不启用 `--insecure-storage`。应检查 GitHub CLI 的认证输出，确认系统凭据存储正常。

执行顺序为：核对本地仓库与目标仓库 → 登录与身份校验 → 测试 → 从发布清单建立初始提交 → 创建远程仓库 → 非强制推送 `main` → 比对本地与远程提交。

首次发布清单是 `scripts/publish-files.txt`，不会把额外放入目录的账号文件或运行缓存自动加入提交。发布前仍需核对清单内文件没有被换成真实用户数据。

## 失败与重复执行

已有非空同名仓库且提交不同，脚本停止，不自动覆盖、不合并、不删除。已有空仓库允许继续，但可见性必须一致。已有远程 `main` 与本地提交相同则返回已发布状态。

推送失败可能只创建了空仓库；先看错误再重试。已有本地未提交或未跟踪文件、错误分支、错误远程地址会阻止脚本继续。脚本只用于首次发布，不代替日常 Git 工作流。

带 `.github/workflows/ci.yml` 的推送可能需要 GitHub 授权的 `workflow` 范围。首次浏览器授权会请求此范围；已有授权不足时，按错误提示交互执行：

```bash
gh auth refresh --hostname github.com --scopes workflow
```

## 发布脚本本地回归

`python3 Tests/PublishingTests/test_publish.py` 可在安装 Python 3 和 Git 的环境中运行。测试中的 GitHub CLI 与网络推送均使用替身，不访问真实账号；实际 Swift 核心回归仍由 `./scripts/test.sh` 执行。

## 发布后验收

推送成功不等于 CI 成功。到 GitHub 的 Actions 页面核对 macOS 构建结果。当前工作流使用 macOS 运行器，测试核心并构建桌面应用，但不执行真实账户扫描或 UI 实机验收，也不会自动发布二进制 Release。

若希望生成正式安装包，先完成 `docs/VALIDATION.md` 的 Mac 验收项，再单独安排签名、公证和 Release。不要把纯 Linux 测试结果称为 macOS 验收通过。

## 命令参考

- GitHub CLI 创建仓库：https://cli.github.com/manual/gh_repo_create
- GitHub CLI 浏览器授权：https://cli.github.com/manual/gh_auth_login
- GitHub CLI 读取仓库信息：https://cli.github.com/manual/gh_repo_view
