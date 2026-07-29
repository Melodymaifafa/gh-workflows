#!/usr/bin/env bash
#
# 把标准分支模型 + 三个 workflow 调用桩装到一个仓库上。
#
#   ./onboard.sh <repo> <python|node>
#
# 做四件事：建 develop 分支、在 develop 上提交调用桩、把 main fast-forward
# 到 develop、刷密钥。密钥从 ~/.config/gh-workflows/secrets.env 读，
# 值不会打印到终端。缺哪个就跳过哪个并提示。
#
# 仓库没有依赖清单 / lint 配置 / 测试时，用环境变量把对应步骤设成 skip，
# 避免第一次接入就满屏红叉：
#   INSTALL_CMD=skip LINT_CMD=skip TEST_CMD=skip ./onboard.sh <repo> node
set -euo pipefail

OWNER=Melodymaifafa
CENTRAL="$OWNER/gh-workflows"
SECRETS_FILE="${GH_WORKFLOWS_SECRETS:-$HOME/.config/gh-workflows/secrets.env}"
STUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stubs"

repo="${1:?usage: onboard.sh <repo> <python|node>}"
runtime="${2:?usage: onboard.sh <repo> <python|node>}"
slug="$OWNER/$repo"

case "$runtime" in
  python | node) ;;
  *)
    echo "runtime must be python or node" >&2
    exit 1
    ;;
esac

echo "==> $slug (runtime=$runtime)"

default_branch="$(gh api "repos/$slug" --jq .default_branch)"
if [ "$default_branch" != main ]; then
  echo "    默认分支是 $default_branch，不是 main；跳过，需要人工确认" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git clone --quiet "https://github.com/$slug.git" "$work/repo"
cd "$work/repo"

# 1. develop 分支：不存在就从 main 切出来
if git ls-remote --exit-code --heads origin develop >/dev/null 2>&1; then
  echo "    develop 已存在"
  git checkout --quiet -B develop origin/develop
else
  echo "    建 develop 分支"
  git checkout --quiet -B develop origin/main
fi

# 2. 调用桩。每个仓库只留这三个小文件，逻辑全在中央仓库。
mkdir -p .github/workflows

# 只有显式传了覆盖值才写进调用桩，没传就留空、走中央仓库的默认命令
overrides=""
for var in INSTALL_CMD LINT_CMD TEST_CMD RUNS_ON; do
  value="${!var:-}"
  if [ -n "$value" ]; then
    key="$(tr '[:upper:]' '[:lower:]' <<<"$var")"
    overrides+="      $key: '$value'"$'\n'
  fi
done
overrides="${overrides%$'\n'}"

for f in ci claude-codex-iterate codex-approved-merge; do
  sed "s|__RUNTIME__|$runtime|g" "$STUB_DIR/$f.yml" >".github/workflows/$f.yml"
done
# __OVERRIDES__ 占位符只在 ci.yml 里；用 python 替换以免 sed 处理多行麻烦
OVERRIDES="$overrides" python3 - <<'PY'
import os, pathlib
p = pathlib.Path(".github/workflows/ci.yml")
body = p.read_text()
block = os.environ.get("OVERRIDES", "")
if block:
    body = body.replace("__OVERRIDES__\n", block + "\n")
else:
    body = body.replace("__OVERRIDES__\n", "")
p.write_text(body)
PY

# 必须先 add 再比对：调用桩是全新文件时 git diff 看不见未跟踪文件，
# 会误报「无需提交」。
git add .github/workflows
if git diff --cached --quiet; then
  echo "    调用桩已是最新，无需提交"
else
  git -c user.name=Melody -c user.email=melodystitchqi@gmail.com \
    commit --quiet -m "ci: adopt shared workflows from $CENTRAL"
  echo "    调用桩已提交"
fi

# develop 可能是刚建的本地分支，无论有没有新 commit 都要推一次
git push --quiet origin develop
echo "    develop 已推送"

# 3. main fast-forward 到 develop。develop 是从 main 切出来的，
#    只多了这一笔，所以一定能 FF；推不动就说明 main 有分叉，报错退出。
if ! git push --quiet origin develop:main 2>/dev/null; then
  echo "    ⚠️  main 无法 fast-forward（有分叉或被保护），请人工处理" >&2
fi

# 4. 密钥。值只在 subshell 里流动，不打印。
if [ -f "$SECRETS_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  set +a
  for name in CLAUDE_CODE_OAUTH_TOKEN CODEX_TRIGGER_TOKEN PUSHOVER_TOKEN PUSHOVER_USER; do
    if [ -n "${!name:-}" ]; then
      gh secret set "$name" --repo "$slug" --body "${!name}" >/dev/null
      echo "    密钥 $name 已设置"
    else
      echo "    密钥 $name 缺失，跳过（该功能在此仓库暂不可用）"
    fi
  done
else
  echo "    ⚠️  找不到 $SECRETS_FILE，本仓库未设置任何密钥" >&2
fi

echo "    完成。还需人工：在 ChatGPT 里把 Codex connector 授权给 $slug"
