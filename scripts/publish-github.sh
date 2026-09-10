#!/bin/bash
# 仅用于这份源码包的首次 GitHub 发布；不读取应用数据，也不覆盖已有远程历史。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OWNER="yzin-17"
REPOSITORY="$OWNER/codex-monitor"
REMOTE_URL="https://github.com/$REPOSITORY.git"
export GH_HOST=github.com

fail() { printf '%s\n' "$*" >&2; exit 1; }
case "${1:-}" in
  --public) VISIBILITY="PUBLIC"; VISIBILITY_FLAG="--public" ;;
  --private) VISIBILITY="PRIVATE"; VISIBILITY_FLAG="--private" ;;
  *) fail "用法：./scripts/publish-github.sh --public 或 --private。必须明确选择可见性。" ;;
esac
[[ $# -eq 1 ]] || fail "只接受一个可见性参数。"
for tool in git swift gh; do
  command -v "$tool" >/dev/null || fail "缺少 $tool。macOS 的 GitHub CLI 可先运行 brew install gh；Swift 需使用 Xcode/Command Line Tools。"
done

# 不得意外操作父目录仓库，也不接管已有的未提交改动。
if TOP="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  [[ "$(cd "$TOP" && pwd -P)" == "$(pwd -P)" ]] || fail "源码位于另一个 Git 仓库内，请先移到独立目录。"
  [[ "$(git branch --show-current)" == "main" ]] || fail "首次发布要求位于 main 分支；不会自动重命名现有分支。"
  [[ -z "$(git status --porcelain)" ]] || fail "已有未提交或未跟踪文件，请先核对、提交或移走；脚本不会自动处理。"
  git rev-parse --verify HEAD >/dev/null 2>&1 || fail "本地 Git 仓库尚无提交，请先自行检查并提交。"
  EXISTING_ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
  case "$EXISTING_ORIGIN" in
    ""|"$REMOTE_URL"|"https://github.com/$REPOSITORY"|"git@github.com:$REPOSITORY.git") ;;
    *) fail "origin 不是 $REPOSITORY，停止发布；不会修改其他仓库地址。" ;;
  esac
elif [[ -e .git ]]; then
  fail "已有无法识别的 .git，停止发布。"
fi

# 浏览器中授权；不要求复制 Token 到聊天、源码或参数。
if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  gh auth login --hostname github.com --web --git-protocol https --scopes workflow
fi
LOGIN="$(gh api --hostname github.com user --jq '.login')"
[[ "$LOGIN" == "$OWNER" ]] || fail "当前 CLI 账号是 $LOGIN，不是 $OWNER。请使用 gh auth switch --hostname github.com --user $OWNER 切换后重试。"

REPO_EXISTS=false
if INFO="$(gh repo view "$REPOSITORY" --json nameWithOwner,isEmpty,visibility --jq '[.nameWithOwner, (.isEmpty | tostring), .visibility] | @tsv' 2>/dev/null)"; then
  REPO_EXISTS=true
  IFS=$'\t' read -r FOUND_NAME IS_EMPTY FOUND_VISIBILITY <<< "$INFO"
  [[ "$FOUND_NAME" == "$REPOSITORY" ]] || fail "GitHub 返回的仓库名称不匹配，停止。"
  [[ "$FOUND_VISIBILITY" == "$VISIBILITY" ]] || fail "已有仓库可见性是 $FOUND_VISIBILITY，与本次参数不一致；不会自动修改可见性。"
  if [[ "$IS_EMPTY" != "true" ]]; then
    LOCAL_HEAD="$(git rev-parse --verify HEAD 2>/dev/null || true)"
    REMOTE_HEAD="$(gh api --hostname github.com "repos/$REPOSITORY/git/ref/heads/main" --jq '.object.sha' 2>/dev/null || true)"
    if [[ -n "$LOCAL_HEAD" && "$LOCAL_HEAD" == "$REMOTE_HEAD" ]]; then
      printf 'GitHub main 已经是当前提交：%s\n仓库：https://github.com/%s\n' "$LOCAL_HEAD" "$REPOSITORY"
      exit 0
    fi
    fail "目标仓库已经有内容，停止首次发布；不会覆盖或合并远程历史。"
  fi
fi

./scripts/test.sh

if [[ ! -e .git ]]; then
  git init -b main
  # 只设置本仓库，并使用已经核对的 GitHub noreply 地址保护个人邮箱。
  git config --local user.name "$OWNER"
  git config --local user.email '30586807+yzin-17@users.noreply.github.com'
  PUBLISH_FILES=()
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    case "$path" in
      /*|../*|*/../*|*/..) fail "发布清单包含不安全路径。" ;;
    esac
    [[ -f "$path" && ! -L "$path" ]] || fail "发布文件缺失或为符号链接：$path"
    PUBLISH_FILES+=("$path")
  done < scripts/publish-files.txt
  [[ ${#PUBLISH_FILES[@]} -gt 0 ]] || fail "发布清单为空。"
  git add -- "${PUBLISH_FILES[@]}"
  git commit -m "feat: initialize offline Codex Monitor with Skills evidence analysis"
fi

# 限制凭据帮助器配置在当前仓库；不输出凭据、不改全局 Git 配置。
git config --local --replace-all credential.https://github.com.helper ''
git config --local --add credential.https://github.com.helper '!gh auth git-credential'

if [[ "$REPO_EXISTS" != "true" ]]; then
  # 网络失败、权限不足或同名仓库存在时 gh 会返回错误，不会覆盖远程仓库。
  gh repo create "$REPOSITORY" "$VISIBILITY_FLAG" \
    --description 'macOS 原生 Codex 对话、子代理 Token 与本地 Skills 证据分析工具' \
    --disable-wiki
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin "$REMOTE_URL"
fi
if ! git push --set-upstream origin main; then
  fail "仓库可能已经创建，但源码推送失败。请核对上方错误；涉及 workflow 权限时可运行 gh auth refresh --hostname github.com --scopes workflow 后重试。不会强制推送。"
fi
LOCAL_HEAD="$(git rev-parse HEAD)"
REMOTE_HEAD="$(gh api --hostname github.com "repos/$REPOSITORY/git/ref/heads/main" --jq '.object.sha')"
[[ "$REMOTE_HEAD" == "$LOCAL_HEAD" ]] || fail "推送后 main 的提交校验不一致，请人工核对；不宣称发布成功。"
printf '\n源码已发布，远程提交已校验：%s\n仓库：https://github.com/%s\nCI：https://github.com/%s/actions\n' "$LOCAL_HEAD" "$REPOSITORY" "$REPOSITORY"
printf '这不是二进制 Release；macOS 编译请查看 CI，窗口交互仍需实机验收。\n'
