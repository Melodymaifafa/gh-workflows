#!/usr/bin/env bash
# bats 套件的共享助手。测试文件用 `load test_helper/common` 引入。

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CI_WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"

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
