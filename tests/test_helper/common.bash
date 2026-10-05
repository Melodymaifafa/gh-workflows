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

# step_key <workflow-file> <step-name> <key>：打印这一步自己那一级的某个键的值
# （timeout-minutes、continue-on-error 之类）。没写就什么都不打印。
step_key() {
  local wf="$1"
  case "$wf" in /*) ;; *) wf="$REPO_ROOT/$wf" ;; esac
  awk -v want="      - name: $2" -v key="        $3:" '
    $0 == want                  { in_step = 1; next }
    in_step && index($0, key) == 1 { sub(/^[^:]*: ?/, ""); print; exit }
    in_step && $0 ~ /^      - / { exit }
  ' "$wf"
}

# run_block_sizes：把所有 workflow 里每个 `run: |` 块的大小打出来，一行一个
# `<字节数> <文件名>:<步骤名>`。actionlint 会把每个块原样写进 shellcheck 的 stdin，
# 块一超过 64 KiB 管道缓冲就两头互等、整个 lint 死锁（MEL-291），所以这是硬约束，
# 不是排版偏好。字节而不是字符：注释是中文，一个字三字节，按字符数会低估三倍。
run_block_sizes() {
  local wf
  for wf in "$REPO_ROOT"/.github/workflows/*.yml; do
    LC_ALL=C awk -v f="${wf##*/}" '
      in_run && $0 ~ /^[[:space:]]*$/ { n += 1; next }
      in_run && $0 ~ /^          /    { n += length($0) - 10 + 1; next }
      in_run                          { print n, f ":" step; in_run = 0 }
      $0 ~ /^      - name: /          { step = substr($0, 15); next }
      $0 == "        run: |"          { in_run = 1; n = 0 }
      END { if (in_run) print n, f ":" step }
    ' "$wf"
  done
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

# ---------------------------------------------------------------------------
# onboard.sh 的调用桩渲染。source 它只会拿到那几个函数：主流程（动远端仓库那段）
# 被 BASH_SOURCE 判定挡住了，所以这里跑的是 onboard.sh 里的真代码。
#
# 测试要覆盖哪条就设 OV_INSTALL / OV_LINT / OV_TEST / OV_RUNS_ON，**不要**直接设
# onboard.sh 读的那四个名字：`ci.yml` 的 Resolve commands 会把 INSTALL_CMD /
# LINT_CMD / TEST_CMD 写进 $GITHUB_ENV，于是这个套件在 CI 里跑时环境里本来就有值。
# 继承它们的话，「没传覆盖值」那几条判定在本机绿、在 CI 红（PR #48 第一版踩过）。
# 下面每次都把那四个名字完整赋一遍，子进程看到的值只由 OV_* 决定。
# ---------------------------------------------------------------------------

# 渲染四个调用桩到 $BATS_TEST_TMPDIR/out/.github/workflows/。
onboard_render() { # onboard_render <python|node>
  INSTALL_CMD="${OV_INSTALL-}" \
  LINT_CMD="${OV_LINT-}" \
  TEST_CMD="${OV_TEST-}" \
  RUNS_ON="${OV_RUNS_ON-}" \
    bash -c '. "$1"; render_stubs "$2" "$3"' \
      _ "$REPO_ROOT/onboard.sh" "$1" "$BATS_TEST_TMPDIR/out"
}

# 只跑「三条全 skip 就警告」那一段，stderr 并进 stdout 好断言。
onboard_coverage_warning() {
  INSTALL_CMD="${OV_INSTALL-}" \
  LINT_CMD="${OV_LINT-}" \
  TEST_CMD="${OV_TEST-}" \
    bash -c '. "$1"; verify_coverage_warning' _ "$REPO_ROOT/onboard.sh" 2>&1
}

# 读回渲染出来的某个调用桩的全文。
rendered_stub() { # rendered_stub <ci.yml|claude-codex-iterate.yml|...>
  cat "$BATS_TEST_TMPDIR/out/.github/workflows/$1"
}

# 渲染出来的 iterate 桩里 verify_cmd 块的第 n 条命令（n 从 1 起，去掉缩进）。
# 注释行（# verify_cmd:）不算：只认行首就是 verify_cmd 的那一行。每条命令各自包在
# 一对独占一行的括号里（子 shell），括号行跳过，只认括号里面多缩进一级的那一行。
rendered_verify_line() { # rendered_verify_line <n>
  awk '
    /^      verify_cmd: \|$/ { f = 1; next }
    f && /^        [()]$/ { next }
    f && /^          / { sub(/^          /, ""); print; next }
    f { exit }
  ' "$BATS_TEST_TMPDIR/out/.github/workflows/claude-codex-iterate.yml" | sed -n "${1}p"
}

# 渲染出来的 verify_cmd 整块（去掉块缩进），就是中央仓库交给 bash -euo pipefail -c
# 的那个脚本。
rendered_verify_block() {
  awk '
    /^      verify_cmd: \|$/ { f = 1; next }
    f && /^        / { sub(/^        /, ""); print; next }
    f { exit }
  ' "$BATS_TEST_TMPDIR/out/.github/workflows/claude-codex-iterate.yml"
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

# ---------------------------------------------------------------------------
# 假命令目录跟「PATH 只认写不动的目录」那道过滤的关系
#
# 有九步在自己的 run: 块里把 PATH 过滤掉所有「这台机器上写得动的目录」——「我们写得
# 动 = 被审 PR 的验证命令也写得动」。tests/test_helper/fake-bin 就在仓库里，谁都写得
# 动，所以过滤之后它必然被滤掉：假 gh、假时钟、假 curl 一个都调不到。这正是过滤要挡
# 的那一类东西，不是 bug。
#
# 于是两种测试要分开：
#   - 安全判定（种一个假 gh，看这一步跑不跑它）跑原样的块，绝不调 trust_fake_bin；
#   - 行为判定（M7 正文长什么样、额度换算对不对、告警去不去重）要的是假命令，不是
#     PATH，所以先调 trust_fake_bin：抽出来的脚本会在过滤那一行之后把假命令目录接
#     回去，其余一字不改。
#
# 写成 opt-in 而不是默认：忘了加 = 那条测试红，看得见；反过来默认接回去、安全判定忘
# 了关掉，就是假绿，看不见。
trust_fake_bin() { FAKE_BIN_TRUSTED=1; }

# 两条路的验证 / 推送跑的是同一段正文：Define the fix verify guard 和 Define the fix
# push guard 两步各一个函数（MEL-262）。两步各自是一个 run: 块，是因为合成一块就超过
# actionlint 喂 shellcheck 那条管道的 64 KiB 缓冲、整个 lint 死锁（MEL-291）。
# fix_guard_body 把其中一个的函数体按 workflow 里写的样子取出来 —— 真跑时它走
# declare -f 出去，排版会变，所以结构判定一律比这份源文本。
fix_guard_body() { # fix_guard_body <verify_the_fix|commit_and_push_the_fix>
  local step
  case "$1" in
    verify_the_fix)          step='Define the fix verify guard' ;;
    commit_and_push_the_fix) step='Define the fix push guard' ;;
    *) echo "fix_guard_body: no step owns $1" >&2; return 1 ;;
  esac
  extract_run_block "$ITERATE_WORKFLOW" "$step" |
    awk -v fn="$1() {" '$0 == fn { f = 1; next } f && $0 == "}" { exit } f { sub(/^  /, ""); print }'
}

# 一段 shell 里那道 PATH 过滤本身：path_is_protected 那行起，到 PATH 被换掉那行止。
trusted_path_filter() {
  awk '/^path_is_protected\(\) \{$/{f=1} f{print} f&&/^PATH="\$trusted_path"$/{exit}'
}

# 某一步 run 块里那段过滤。验证 / 推送那四步的正文不在步骤里，用 step_path_guard。
trusted_path_block() { # trusted_path_block <step>
  extract_run_block "$ITERATE_WORKFLOW" "$1" | trusted_path_filter
}

# step_path_guard <step>：这一步真正跑的那份 path_is_protected。验证 / 推送那四步跑的
# 是共用正文里的函数，所以先看它 eval 的是哪一个，再去定义它的那一步里取；其余几步
# 正文就写在自己的 run 块里。九个带凭据的步骤靠这个助手比成同一份。
step_path_guard() { # step_path_guard <step>
  local block fn
  block="$(extract_run_block "$ITERATE_WORKFLOW" "$1")"
  fn="$(printf '%s\n' "$block" | awk '/^(verify_the_fix|commit_and_push_the_fix)$/ { print; exit }')"
  [ -z "$fn" ] || block="$(fix_guard_body "$fn")"
  printf '%s\n' "$block" |
    awk '/^path_is_protected\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}'
}

# path_guard <step> <dir>：只把那段里的 path_is_protected 抽出来，问它信不信一个目录。
# 输出 protected / rejected / hung。带看门狗是因为「逐级往上剥」的写法碰到不带 / 的
# 相对项会原地打转 —— 没有看门狗，这种 bug 的长相是整套测试挂死，不是一条红。
path_guard() {
  local script pid wd rc=0
  script="$BATS_TEST_TMPDIR/path-guard-$$.sh"
  trusted_path_block "$1" |
    awk '/^path_is_protected\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' >"$script"
  # shellcheck disable=SC2016  # 写进脚本的就是字面量 $1
  printf 'path_is_protected "$1"\n' >>"$script"
  bash "$script" "$2" >/dev/null 2>&1 &
  pid=$!
  { /bin/sleep 5; kill -9 "$pid"; } >/dev/null 2>&1 &
  wd=$!
  wait "$pid" || rc=$?
  kill "$wd" >/dev/null 2>&1 || true
  case "$rc" in
    0) echo protected ;;
    1) echo rejected ;;
    *) echo hung ;;
  esac
}

# plant_fake_tools <dir> <tool>...：往一个「我们写得动」的目录里种几个假命令，再把它
# 挂到 PATH 最前面 —— 这就是 ubuntu-latest 上 $HOME/.local/bin 那几项的样子，被审 PR
# 自己的验证命令跟我们同一个用户，写得动。假命令一被执行就把当时手上的令牌记进
# $PLANTED_LOG：文件非空 = 令牌递出去了。
plant_fake_tools() {
  local dir="$1" tool
  shift
  mkdir -p "$dir"
  export PLANTED_LOG="$BATS_TEST_TMPDIR/planted.log"
  : >"$PLANTED_LOG"
  for tool in "$@"; do
    cat >"$dir/$tool" <<EOS
#!/bin/sh
printf '$tool %s | GH_TOKEN=%s\n' "\$*" "\${GH_TOKEN:-}" >>"\$PLANTED_LOG"
EOS
    chmod +x "$dir/$tool"
    [ -x "$dir/$tool" ] || { echo "plant_fake_tools: could not plant $tool" >&2; return 1; }
  done
  export PATH="$dir:$PATH"
}

refute_planted_ran() {
  [ -s "${PLANTED_LOG:?plant_fake_tools was never called}" ] || return 0
  printf 'the planted command ran: %s\n' "$(cat "$PLANTED_LOG")" >&2
  return 1
}

# 对照：把同一个种了假命令的目录当成「可信」接回 PATH，这一步就真去跑它了。
# 少了这一半，上面那条 refute 可能只是因为假命令压根没被种上 —— 空转的绿。
assert_planted_runs_when_trusted() {
  [ -s "$PLANTED_LOG" ] && return 0
  echo 'control run: the planted command was never reachable at all' >&2
  return 1
}

# run_block <workflow-file> <step-name>：抽出 step 的 run: | 块，按 GitHub 默认 shell
# （bash --noprofile --norc -eo pipefail）执行。workflow 路径可写相对仓库根目录。
# 块里有 ${{ }} 直接报错：表达式要挪到 env:，测试靠环境变量喂值。
# 注意本机 macOS 的 bash 是 3.2，CI 上是 5.x；块里别用 bash 4+ 专有语法。
run_block() {
  local wf="$1" step="$2" script
  case "$wf" in /*) ;; *) wf="$REPO_ROOT/$wf" ;; esac
  [ -f "$wf" ] || { echo "run_block: no workflow file $wf" >&2; return 98; }
  # 纯 bash 转换，不借 sed：种假命令的那几条测试会把一个假 sed 挂到 PATH 最前面，
  # 助手自己去跑它就等于在 step 还没开始前先污染战利品日志。
  script="$BATS_TEST_TMPDIR/block-${step//[^A-Za-z0-9]/_}.sh"
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
  # trust_fake_bin 说了才接：在过滤那一行之后把假命令目录加回 PATH 最前面。
  # 这一步没有那道过滤时什么也不做 —— 假命令本来就在 PATH 上。
  if [ "${FAKE_BIN_TRUSTED:-}" = 1 ]; then
    trust_patch <"$script" >"$script.trusted"
    mv "$script.trusted" "$script"
    # 验证 / 推送那四步的正文不在块里，而在 eval 进来的那两段里（MEL-262）：同一下
    # 补丁要打在它们身上，否则 trust_fake_bin 对这四步静默失效，判定跟着空转。
    # 只在这一次调用里生效。
    (
      FIX_VERIFY_GUARD="$(printf '%s\n' "${FIX_VERIFY_GUARD:-}" | trust_patch)"
      FIX_PUSH_GUARD="$(printf '%s\n' "${FIX_PUSH_GUARD:-}" | trust_patch)"
      export FIX_VERIFY_GUARD FIX_PUSH_GUARD
      bash --noprofile --norc -eo pipefail "$script"
    )
    return
  fi
  bash --noprofile --norc -eo pipefail "$script"
}

# 把假命令目录接回 PATH 最前面，插在那道过滤之后。两种长相都认：步骤块里是顶格的
# `PATH="$trusted_path"`，共用正文走 declare -f 出来会缩进、还带个分号。
trust_patch() {
  awk -v d="$FAKE_BIN_DIR" '
    { print }
    !patched && $0 ~ /^[[:space:]]*PATH="\$trusted_path";?$/ { print "PATH=\"" d ":$PATH\""; patched = 1 }
  '
}

# scope_proc_sweep_to_this_run：验证正文那道「清点残留活进程」问的是「这个 uid 名下
# 有谁」。runner 上进程表干净，那句话等于「本次 run 自己起的有谁」；本机不等于 ——
# 同一个用户名下还有一堆外人，实测全都被记成「验证命令留下的」过（MEL-304）：
#   ① 隔壁 worker 的 `bats tests/`（池子一轮最多 3 个 worker，同一个仓库撞上两个是
#      常态）。两套并发，两边各红 19 条，每次红的还不是同几条。
#   ② macOS 按需拉起来的服务（networkserviceproxy、iCloud 的助手、Spotlight 的索引
#      进程），开着的桌面应用（Chrome 的渲染进程），以及 agent 池自己的进程。
#      它们在验证命令跑的那几秒里才起来，于是进不了基线。
#
# 所以给验证正文一份只答本次 run 自己进程的 ps（tests/test_helper/sweep-bin/ps，
# 怎么认见那个文件开头）。防线正文一个字不改 —— 收窄发生在「谁来回答 ps」这一层，
# 判据（除了基线里那些和我们自己的后代，一个都不许有）照旧，探针照旧要被它自己的
# 逻辑抓出来。
#
# 这条规则的失败方向是「少报」，所以它必须有自测，而且有：每个会活过验证命令的探针
# 都有一条测试要求清点把它报出来（codex-takeover 里那几条 escapee / idle daemon /
# leftover）。认不出探针 = 那几条当场红，不是悄悄绿。实测抓到过两次 —— 一次是探针
# 最后 exec 成 /bin/sleep、argv 里线索全没了，一次是噪声重跑没把探针状态退回去。
#
# 认「哪些是本次 run 的」靠 argv 里带不带本次 run 的临时目录，所以每个会活过验证
# 命令的探针都写成「从那个目录下的一个脚本起」（见 leftover_probe）。光靠 argv 不够的
# 两种各自先把自己的 pid 报给那份 ps：故意 exec 掉这条线索的那一个（见那条 idle daemon
# 旁边的注释），以及被过继给 1 号进程、命令行又可能一瞬读不出来的那个（噪声重跑那一条）。
# 噪声重跑也会把探针的 pid 文件清空（见 reset_workspace）。
#
# 还有一条：别顺着父子链一路往上走。往上走会碰到「我们和隔壁 worker 共同的那个祖先」
# （跑这一轮的那个 shell），于是隔壁整棵树连带算成我们的，筛选变成空操作（实测踩过）。
# 所以只走到本次这一步的 shell 为止。
#
# 反证开关：`GHWF_SWEEP_UNSCOPED=1 bats tests/` 把 ps 换回全机那一份，并发场景立刻
# 重新变红。筛选条件只在测试里存在，workflow 从不读它。
SWEEP_BIN_DIR="$REPO_ROOT/tests/test_helper/sweep-bin"

scope_proc_sweep_to_this_run() {
  [ "${GHWF_SWEEP_UNSCOPED:-}" != 1 ] || return 0
  [ -n "${FIX_VERIFY_GUARD:-}" ] || {
    echo 'scope_proc_sweep_to_this_run: FIX_VERIFY_GUARD is not set yet' >&2
    return 1
  }
  local patched
  patched="$(printf '%s\n' "$FIX_VERIFY_GUARD" | awk -v d="$SWEEP_BIN_DIR" '
    { print }
    !done && $0 ~ /^[[:space:]]*PATH="\$trusted_path";?$/ { print "PATH=\"" d ":$PATH\""; done = 1 }
    END { if (!done) exit 1 }
  ')" || {
    echo 'scope_proc_sweep_to_this_run: the verify guard no longer filters PATH; the scoped ps was not installed' >&2
    return 1
  }
  FIX_VERIFY_GUARD="$patched"
  export FIX_VERIFY_GUARD
}

# step_env_keys <workflow-file> <step-name>：打印这一步 `env:` 块里声明的变量名，
# 一行一个。守「这一步不许拿到某个变量」这类性质要靠它：run_block 只抽 run: 块，
# 环境是测试自己喂的，光看块里写了什么看不出 step 真跑起来手上有哪些值。
# 块里的注释行和空行要跳过、不能当成「env 到这儿结束」：停在第一条注释上的话，
# 注释后面声明的变量这个助手压根看不见 —— 那种「某一步不许有令牌」的判定于是假绿。
step_env_keys() {
  local wf="$1"
  case "$wf" in /*) ;; *) wf="$REPO_ROOT/$wf" ;; esac
  awk -v want="      - name: $2" '
    $0 == want                                       { in_step = 1; next }
    in_step && !in_env && $0 == "        env:"        { in_env = 1; next }
    in_env && $0 ~ /^ *(#|$)/                         { next }
    in_env && $0 ~ /^          [A-Za-z_][A-Za-z0-9_]*:/ {
      sub(/^ +/, ""); sub(/:.*$/, ""); print; next
    }
    in_env                                            { exit }
    in_step && $0 ~ /^      - /                       { exit }
  ' "$wf"
}

# step_env_literals <workflow-file> <step-name>：打印这一步 `env:` 里写死的字面量
# （值里没有 ${{ }} 的那些，比如 FIXER: Claude），一行一个 `KEY=value`。表达式那些
# 跳过 —— 它们的值只有真跑起来才知道，由测试自己喂。
step_env_literals() {
  local wf="$1"
  case "$wf" in /*) ;; *) wf="$REPO_ROOT/$wf" ;; esac
  awk -v want="      - name: $2" '
    $0 == want                                       { in_step = 1; next }
    in_step && !in_env && $0 == "        env:"        { in_env = 1; next }
    in_env && $0 ~ /^ *(#|$)/                         { next }
    in_env && $0 ~ /^          [A-Za-z_][A-Za-z0-9_]*:/ {
      line = $0; sub(/^ +/, "", line)
      k = line; sub(/:.*$/, "", k)
      v = line; sub(/^[^:]*: ?/, "", v)
      if (index(v, "${{") == 0 && v != "") print k "=" v
      next
    }
    in_env                                            { exit }
    in_step && $0 ~ /^      - /                       { exit }
  ' "$wf"
}

# run_step <workflow-file> <step-name>：同 run_block，但先按这一步的 `env:` 把环境
# 摆成真跑起来的样子 —— 没声明的令牌摘掉，写死的字面量照 workflow 里写的喂进去。
# 「令牌照挂在 step 级 env、只在子进程里 env -u 抹掉」的写法在这里会原样暴露：
# 父 shell 那份环境还在，验证命令跟它同一个用户，/proc/$PPID/environ 读得回来。
# 字面量照喂是因为两条路现在共用同一段正文，差别只在 $FIXER 这类值上：测试要验的
# 是 workflow 里写的那个值，不是测试自己编一个塞进去。
run_step() {
  local wf="$1" step="$2" keys lit
  keys="$(step_env_keys "$wf" "$step")"
  [ -n "$keys" ] || { echo "run_step: step '$step' declares no env: block in $wf" >&2; return 98; }
  (
    case "$keys" in *GH_TOKEN*) ;; *) unset GH_TOKEN ;; esac
    case "$keys" in *GITHUB_TOKEN*) ;; *) unset GITHUB_TOKEN ;; esac
    while IFS= read -r lit; do
      [ -n "$lit" ] || continue
      export "${lit?}"
    done <<EOF
$(step_env_literals "$wf" "$step")
EOF
    run_block "$wf" "$step"
  )
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
