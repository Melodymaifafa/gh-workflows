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

# ---------------------------------------------------------------------------
# 渲染调用桩的那几个函数。单列出来是为了让 tests/onboard-verify-cmd.bats 直接
# source 本文件调它们 —— 测试跑的是这里的真代码，不是复制过去的一份（复制的那份
# 迟早和这里各改各的）。它们只读环境变量、只写给定目录，不碰网络。
# ---------------------------------------------------------------------------

# ci.yml 的 __OVERRIDES__ 块。只有显式传了覆盖值的键才写进去，
# 没传的键留空、走中央仓库按 runtime 的默认命令。
ci_overrides() {
  local var value key out=''
  for var in INSTALL_CMD LINT_CMD TEST_CMD RUNS_ON; do
    value="${!var:-}"
    [ -n "$value" ] || continue
    key="$(tr '[:upper:]' '[:lower:]' <<<"$var")"
    out+="      $key: '$value'"$'\n'
  done
  printf '%s' "$out"
}

# 一条验证命令。ci.yml 的 skip 在那一步里是「打一条 notice 然后退出 0」，
# 所以修复那一轮要跟它一致就得翻成同样一条 notice：原样写 skip 会被当成命令、
# 找不到就 127 整轮红；写成空行则中央仓库判定「没有验证命令」拒绝推送。
verify_line() {
  local kind="$1" cmd="$2"
  if [ "$cmd" = skip ]; then
    printf 'echo "::notice::%s skipped by caller"' "$kind"
  else
    printf '%s' "$cmd"
  fi
}

# iterate 调用桩的 __VERIFY_CMD__ 块。三条里任意一条被覆盖过就整块写出来，
# 没覆盖的那几条用跟 ci.yml 逐字相同的默认值填齐 —— verify_cmd 是整份替换、
# 不是逐行合并，只写被覆盖的那一条会让另两条从修复那一轮里整个消失（MEL-303）。
# 三条都没覆盖就什么都不打印，让中央仓库的默认值生效。
iterate_verify_cmd() {
  local runtime="$1"
  local default_install default_lint default_test

  # 这三条必须跟 .github/workflows/ci.yml 的 Resolve commands 逐字一样，
  # tests/onboard-verify-cmd.bats 有一条判定把两边钉在一起。
  case "$runtime" in
    python)
      default_install='uv sync --dev'
      default_lint='uv run ruff check .'
      default_test='uv run pytest'
      ;;
    node)
      default_install='if [ -f package-lock.json ]; then npm ci; else npm install; fi'
      default_lint='npm run lint --if-present'
      default_test='npm run test --if-present'
      ;;
    *)
      echo "iterate_verify_cmd: unknown runtime '$runtime'" >&2
      return 1
      ;;
  esac

  [ -n "${INSTALL_CMD:-}${LINT_CMD:-}${TEST_CMD:-}" ] || return 0

  printf '      verify_cmd: |\n'
  printf '        %s\n' \
    "$(verify_line install "${INSTALL_CMD:-$default_install}")" \
    "$(verify_line lint "${LINT_CMD:-$default_lint}")" \
    "$(verify_line test "${TEST_CMD:-$default_test}")"
}

# 三条全 skip：CI 一条都不跑，修复那一轮的 verify_cmd 也只剩三条 notice ——
# 等于 Claude 的修复没经过任何检查就推上 PR。这不是新开的洞（CI 本来也不验证），
# 但它只有在接入这一刻说得出口，之后没人会再看一眼生成出来的调用桩。
verify_coverage_warning() {
  [ "${INSTALL_CMD:-}" = skip ] && [ "${LINT_CMD:-}" = skip ] && [ "${TEST_CMD:-}" = skip ] || return 0
  echo "    ⚠️  装 / lint / 测三条都是 skip：CI 和修复那一轮都不会真验证任何东西，" >&2
  echo "        Claude 的修复会直接推上 PR。三条里任意一条给上真命令就能恢复验证。" >&2
}

# 把四个调用桩渲染进 <dest>/.github/workflows/。<dest> 默认当前目录。
render_stubs() {
  local runtime="$1" dest="${2:-.}" f
  mkdir -p "$dest/.github/workflows"
  for f in ci claude-codex-iterate codex-approved-merge ff-main; do
    sed "s|__RUNTIME__|$runtime|g" "$STUB_DIR/$f.yml" >"$dest/.github/workflows/$f.yml"
  done
  # 两个占位符都是多行块，用 python 替换以免 sed 处理多行麻烦
  WORKFLOW_DIR="$dest/.github/workflows" \
  OVERRIDES="$(ci_overrides)" \
  VERIFY_BLOCK="$(iterate_verify_cmd "$runtime")" \
    python3 - <<'PY'
import os, pathlib

d = pathlib.Path(os.environ["WORKFLOW_DIR"])
for name, placeholder, key in (
    ("ci.yml", "__OVERRIDES__\n", "OVERRIDES"),
    ("claude-codex-iterate.yml", "__VERIFY_CMD__\n", "VERIFY_BLOCK"),
):
    # 命令替换把块尾的换行吃掉了，补回来；空块整行删掉。
    block = os.environ.get(key, "")
    if block and not block.endswith("\n"):
        block += "\n"
    p = d / name
    p.write_text(p.read_text().replace(placeholder, block))
PY
}

# 被测试 source 时只要上面那几个函数，下面的主流程（会动远端仓库）不跑。
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

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
#    覆盖值同时写两处：ci.yml 的 install/lint/test，和 iterate 桩的 verify_cmd。
#    只写前者的话 CI 绿着、修复那一轮必然红（MEL-303）。
render_stubs "$runtime"
verify_coverage_warning

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
main_ff_ok=true
if ! git push --quiet origin develop:main 2>/dev/null; then
  main_ff_ok=false
  echo "    ⚠️  main 无法 fast-forward（有分叉或被保护），请人工处理" >&2
fi

# 4. 默认分支。接入完成后，日常 PR 和 agent 都应该默认打到 develop。
#    忘了这步会把 gh pr create / agent PR 送进 main，绕开泡期。
if [ "$main_ff_ok" = true ]; then
  if gh repo edit "$slug" --default-branch develop >/dev/null; then
    echo "    默认分支已改为 develop"
  else
    echo "    ⚠️  默认分支未能自动改成 develop，请手动执行：gh repo edit $slug --default-branch develop" >&2
  fi
else
  echo "    ⚠️  main 未快进，跳过默认分支切换，避免半接入状态" >&2
fi

# 5. 密钥。值只在 subshell 里流动，不打印。
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

# Codex connector 是账号级授权，新仓库自动覆盖（2026-07-29 实测），这里不用管。
echo "    完成。"
