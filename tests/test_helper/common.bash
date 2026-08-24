#!/usr/bin/env bash
# bats 套件的共享助手。测试文件用 `load test_helper/common` 引入。

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CI_WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"
ITERATE_WORKFLOW="$REPO_ROOT/.github/workflows/claude-codex-iterate.yml"
SCRIPTS="$REPO_ROOT/scripts"

# 打印 workflow 里某个 step 的 `run: |` 块，去掉 10 空格缩进。
# 测试跑的是 ci.yml 里那段真代码——在测试里复制一份逻辑，两边迟早各改各的。
extract_run_block() {
  local workflow="$1" step_name="$2"
  awk -v want="      - name: ${step_name}" '
    $0 == want            { in_step = 1; next }
    in_step && !in_run && $0 == "        run: |" { in_run = 1; next }
    in_run {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      if ($0 !~ /^          /)   { exit }
      sub(/^          /, "")
      print
    }
  ' "$workflow"
}

# 用指定 runtime 跑一遍 Resolve commands，结果落到 $GITHUB_ENV 指向的文件。
# 三个 *_OVERRIDE 默认空串，对应调用方没传 install_cmd / lint_cmd / test_cmd。
resolve_commands() {
  local runtime="$1"
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  : >"$GITHUB_ENV"
  extract_run_block "$CI_WORKFLOW" "Resolve commands" >"$BATS_TEST_TMPDIR/resolve.sh"
  RUNTIME="$runtime" \
  INSTALL_OVERRIDE="${INSTALL_OVERRIDE:-}" \
  LINT_OVERRIDE="${LINT_OVERRIDE:-}" \
  TEST_OVERRIDE="${TEST_OVERRIDE:-}" \
    bash "$BATS_TEST_TMPDIR/resolve.sh"
}

# 读回 Resolve commands 写进 GITHUB_ENV 的某个变量。
resolved() {
  sed -n "s/^$1=//p" "$BATS_TEST_TMPDIR/github_env"
}

# 断言写成函数，不要在测试里直接写 `[[ ... ]]`：
# bats 会漏掉中途失败的 `[[ ]]`，只看最后一条命令的退出码，测试于是假绿。
# 函数返回非零它抓得住，顺带还能打出「期望什么 / 实际什么」。
assert_equal() {
  if [ "$1" != "$2" ]; then
    printf 'expected: %s\n  actual: %s\n' "$2" "$1" >&2
    return 1
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) printf 'expected to contain: %s\n             actual: %s\n' "$2" "$1" >&2; return 1 ;;
  esac
}

refute_contains() {
  case "$1" in
    *"$2"*) printf 'expected NOT to contain: %s\n                 actual: %s\n' "$2" "$1" >&2; return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# 假 GitHub 环境：gh / curl / sleep / date 换成 tests/test_helper/fake-bin 里的假命令。
#
# setup_fake_env 之后：
#   FAKE_DIR     $BATS_TEST_TMPDIR/fake，假命令的全部状态都在这里
#   FAKE_GH_DIR  $FAKE_DIR/gh，响应 fixture（用 fake_route / fake_cli 写，别手写路径）
#   FAKE_LOG     $FAKE_DIR/calls.log，每次调用一行（换行写成 \n）
#   FAKE_NOW     可选，ISO 8601（2026-09-18T08:00:00Z）或 @epoch；设了 date 就用假时钟，
#                假 sleep N 会把假时钟往前拨 N 秒
#
# gh api 响应文件：$FAKE_GH_DIR/api/<METHOD>/<key>[.<n>].json（+ 可选同名 .exit）
#   key = 路由去掉开头 /，[A-Za-z0-9._-] 以外的字符换成 _（查询串也算在内）。
#   有 .<n> 就是序列：第 n 次调用取 .<n>，超出最后一个就一直重复最后一个。
#   GET 没 fixture → exit 97；非 GET 没 fixture → 输出 {}。
#   --paginate --slurp 把单页 fixture 包成 [page]；--jq/-q 用真 jq -r 处理。
#   没写 -X 但带了 -f/-F/--input → POST（同真 gh）；GET 带 -f 时字段拼进查询串。
# 其它 gh 子命令：$FAKE_GH_DIR/cli/<group>_<sub>[.<n>].out（+ .exit），如 pr_view、pr_checks。
#   没 fixture 时 pr comment 输出一个假评论 URL，pr merge/edit/close/ready、workflow * 静默成功，
#   其余 exit 97。
# ---------------------------------------------------------------------------

FAKE_BIN_DIR="$REPO_ROOT/tests/test_helper/fake-bin"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures"
# shellcheck source=tests/test_helper/fake-bin/_lib.sh
. "$FAKE_BIN_DIR/_lib.sh"

setup_fake_env() {
  export FAKE_DIR="$BATS_TEST_TMPDIR/fake"
  export FAKE_GH_DIR="$FAKE_DIR/gh"
  export FAKE_LOG="$FAKE_DIR/calls.log"
  mkdir -p "$FAKE_GH_DIR/api" "$FAKE_GH_DIR/cli" "$FAKE_DIR/state" "$FAKE_DIR/bodies"
  : >"$FAKE_LOG"
  case ":$PATH:" in
    *":$FAKE_BIN_DIR:"*) ;;
    *) export PATH="$FAKE_BIN_DIR:$PATH" ;;
  esac
  export TZ=UTC
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/github_step_summary"
  : >"$GITHUB_OUTPUT"; : >"$GITHUB_ENV"; : >"$GITHUB_STEP_SUMMARY"
}

# 参数是已存在的文件、tests/fixtures 下的相对路径，或者字面 JSON/文本。
_fake_write() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [ -f "$src" ]; then
    cp "$src" "$dest"
  elif [ -n "$src" ] && [ -f "$FIXTURES_DIR/$src" ]; then
    cp "$FIXTURES_DIR/$src" "$dest"
  else
    printf '%s\n' "$src" >"$dest"
  fi
}

# fake_route [-X METHOD] <route> <json-or-file> [seq]
fake_route() {
  local method=GET
  if [ "$1" = -X ]; then method="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"; shift 2; fi
  local key; key="$(fake_route_key "$1")"
  _fake_write "$2" "$FAKE_GH_DIR/api/$method/$key${3:+.$3}.json"
}

# fake_route_fail [-X METHOD] <route> <exit-code> [json-body] [seq]
fake_route_fail() {
  local method=GET
  if [ "$1" = -X ]; then method="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"; shift 2; fi
  local key base; key="$(fake_route_key "$1")"
  base="$FAKE_GH_DIR/api/$method/$key${4:+.$4}"
  mkdir -p "$(dirname "$base")"
  echo "$2" >"$base.exit"
  [ -z "${3:-}" ] || _fake_write "$3" "$base.json"
}

# fake_cli <group_sub> <output-or-file> [seq]，如 fake_cli pr_view '{"headRefOid":"abc"}'
fake_cli() {
  _fake_write "$2" "$FAKE_GH_DIR/cli/$1${3:+.$3}.out"
}

# fake_cli_fail <group_sub> <exit-code> [output] [seq]
fake_cli_fail() {
  local base="$FAKE_GH_DIR/cli/$1${4:+.$4}"
  mkdir -p "$(dirname "$base")"
  echo "$2" >"$base.exit"
  [ -z "${3:-}" ] || _fake_write "$3" "$base.out"
}

# fake_calls [fixed-string]：打印日志里含该子串的行（不给参数就打印全部）。
fake_calls() {
  if [ "$#" -eq 0 ]; then cat "$FAKE_LOG"; else grep -F -- "$1" "$FAKE_LOG"; fi
}

fake_count() {
  grep -cF -- "$1" "$FAKE_LOG" || true
}

# assert_called <fixed-string> [times]：不给次数 = 至少一次。
assert_called() {
  local n; n="$(fake_count "$1")"
  if [ "$#" -ge 2 ]; then
    [ "$n" -eq "$2" ] && return 0
    printf 'expected %s call(s) matching: %s\n  got %s. log:\n' "$2" "$1" "$n" >&2
  else
    [ "$n" -gt 0 ] && return 0
    printf 'expected a call matching: %s\n  log:\n' "$1" >&2
  fi
  sed 's/^/    /' "$FAKE_LOG" >&2
  return 1
}

refute_called() {
  local n; n="$(fake_count "$1")"
  [ "$n" -eq 0 ] && return 0
  printf 'expected NO call matching: %s\n  got:\n' "$1" >&2
  grep -F -- "$1" "$FAKE_LOG" | sed 's/^/    /' >&2
  return 1
}

# fake_last_body <fixed-string>：最后一条匹配调用发出去的正文（原样，含换行）。
# 正文来源：gh api 的 body= 字段或 --input JSON 的 .body；gh pr comment 的 --body/-F；
# curl 的 message= 字段。
fake_last_body() {
  local n
  n="$(grep -nF -- "$1" "$FAKE_LOG" | tail -n 1 | cut -d: -f1)"
  [ -n "$n" ] || { echo "fake_last_body: no call matching: $1" >&2; return 1; }
  [ -f "$FAKE_DIR/bodies/$n" ] || { echo "fake_last_body: call $n has no body" >&2; return 1; }
  cat "$FAKE_DIR/bodies/$n"
}

# fake_all_bodies：所有带正文的调用的正文，逐个输出，中间隔一行 ----
fake_all_bodies() {
  local f
  for f in "$FAKE_DIR"/bodies/*; do
    [ -e "$f" ] || continue
    cat "$f"; printf '\n----\n'
  done
}

# 当前假时钟（epoch 秒）。需要 FAKE_NOW。
fake_now_epoch() {
  fake_clock_epoch
}

# run_block <workflow-file> <step-name>：抽出 step 的 run: | 块，按 GitHub 默认 shell
# （bash --noprofile --norc -eo pipefail）执行。workflow 路径可写相对仓库根目录。
# 块里有 ${{ }} 直接报错：表达式要挪到 env:，测试靠环境变量喂值。
# 注意本机 macOS 的 bash 是 3.2，CI 上是 5.x；块里别用 bash 4+ 专有语法。
run_block() {
  local wf="$1" step="$2" script
  case "$wf" in /*) ;; *) wf="$REPO_ROOT/$wf" ;; esac
  [ -f "$wf" ] || { echo "run_block: no workflow file $wf" >&2; return 98; }
  script="$BATS_TEST_TMPDIR/block-$(printf '%s' "$step" | LC_ALL=C sed 's/[^A-Za-z0-9]/_/g').sh"
  extract_run_block "$wf" "$step" >"$script"
  if ! grep -q '[^[:space:]]' "$script"; then
    echo "run_block: step '$step' not found or has no 'run: |' block in $wf" >&2
    return 98
  fi
  # shellcheck disable=SC2016  # 找的就是字面量 ${{
  if grep -qF '${{' "$script"; then
    echo "run_block: step '$step' uses \${{ }} inside run:; move it to env:" >&2
    return 98
  fi
  bash --noprofile --norc -eo pipefail "$script"
}

# step_output <name>：读回 $GITHUB_OUTPUT 里的值（支持 name=v 和 name<<EOF 多行写法，后写的赢）。
step_output() {
  awk -v want="$1" '
    delim != "" {
      if ($0 == delim) { if (name == want) { val = buf; found = 1 }; delim = ""; next }
      buf = (started ? buf "\n" : "") $0; started = 1; next
    }
    match($0, /^[A-Za-z_][A-Za-z0-9_-]*<</) {
      name = substr($0, 1, RLENGTH - 2); delim = substr($0, RLENGTH + 1); buf = ""; started = 0; next
    }
    index($0, want "=") == 1 { val = substr($0, length(want) + 2); found = 1 }
    END { if (found) print val; else exit 1 }
  ' "$GITHUB_OUTPUT"
}

# ---------- 造 GitHub JSON 的小工具（输出单个对象，json_array 拼成数组） ----------

# gh_comment <id> <login> <association> <body> [created_at]
gh_comment() {
  jq -n --argjson id "$1" --arg login "$2" --arg assoc "$3" --arg body "$4" \
    --arg at "${5:-2026-09-18T08:00:00Z}" '{
      id: $id, body: $body, author_association: $assoc,
      user: {login: $login, type: (if ($login | endswith("[bot]")) then "Bot" else "User" end)},
      created_at: $at, updated_at: $at,
      html_url: "https://github.com/o/r/pull/1#issuecomment-\($id)"
    }'
}

# gh_review <id> <login> <association> <commit_id> <body> [submitted_at] [state]
gh_review() {
  jq -n --argjson id "$1" --arg login "$2" --arg assoc "$3" --arg sha "$4" --arg body "$5" \
    --arg at "${6:-2026-09-18T08:00:00Z}" --arg state "${7:-COMMENTED}" '{
      id: $id, body: $body, author_association: $assoc, commit_id: $sha, state: $state,
      user: {login: $login, type: (if ($login | endswith("[bot]")) then "Bot" else "User" end)},
      submitted_at: $at,
      html_url: "https://github.com/o/r/pull/1#pullrequestreview-\($id)"
    }'
}

# gh_reaction <content> <login> [created_at]，content 如 eyes、+1
gh_reaction() {
  jq -n --arg c "$1" --arg login "$2" --arg at "${3:-2026-09-18T08:00:00Z}" '{
      id: 1, content: $c, created_at: $at,
      user: {login: $login, type: (if ($login | endswith("[bot]")) then "Bot" else "User" end)}
    }'
}

# json_array [obj ...]：没参数输出 []
json_array() {
  if [ "$#" -eq 0 ]; then echo '[]'; return; fi
  printf '%s\n' "$@" | jq -s .
}

# ---------- 共享契约里的标记正文（只用来造「已有状态」；断言输出时请写字面量） ----------

# m1_body <H> [fix-round-N | kick]
m1_body() {
  local b
  b="$(printf '@codex review\n\n<!-- codex-review-head: %s -->' "$1")"
  case "${2:-}" in
    '') ;;
    kick) b="$b"$'\n''<!-- pr-sweeper: kick -->' ;;
    *) b="$b"$'\n'"<!-- fix-round: $2 -->" ;;
  esac
  printf '%s' "$b"
}

# m3_body <H>：Claude 代审有问题（review 正文）
m3_body() {
  # shellcheck disable=SC2016  # 反引号是 markdown，不是命令替换
  printf '### 🤖 Claude 代审（Codex 本次不可用）\n\n- P1 `a.sh:1` 示例问题\n\n<!-- claude-review-findings: %s -->' "$1"
}

# m4_body <H>：Claude 代审没问题（issue 评论）
m4_body() {
  printf '🤖 Claude 代审：没发现要改的问题（Codex 本次不可用）。CI 全绿后自动合并。\n\n<!-- claude-review-clean: %s -->' "$1"
}

# m6_marker <H> <reason> [until]
m6_marker() {
  printf '<!-- pr-guard: alert head=%s reason=%s until=%s -->' "$1" "$2" "${3:--}"
}
