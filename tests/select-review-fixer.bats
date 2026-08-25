#!/usr/bin/env bats
# scripts/select-review-fixer.sh —— 决定这一轮谁修 PR、允不允许换人。
# 这段决定的是「拿着写权限 token 的是哪个 agent」，判错了没人会立刻发现。

load test_helper/common

setup() {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  : >"$GITHUB_OUTPUT"
}

# 输出里某个 key 的值。
picked() {
  sed -n "s/^$1=//p" "$GITHUB_OUTPUT"
}

@test "auto runs Claude first and keeps the Codex fallback open" {
  run "$SCRIPTS/select-review-fixer.sh" auto
  assert_equal "$status" 0
  assert_equal "$(picked first)" claude
  assert_equal "$(picked fallback_allowed)" true
}

@test "claude never falls back" {
  run "$SCRIPTS/select-review-fixer.sh" claude
  assert_equal "$status" 0
  assert_equal "$(picked first)" claude
  assert_equal "$(picked fallback_allowed)" false
}

@test "codex skips Claude entirely" {
  run "$SCRIPTS/select-review-fixer.sh" codex
  assert_equal "$status" 0
  assert_equal "$(picked first)" codex
  assert_equal "$(picked fallback_allowed)" false
}

@test "a misspelled value fails loudly instead of falling back to the default" {
  run "$SCRIPTS/select-review-fixer.sh" codx
  assert_equal "$status" 1
  assert_contains "$output" "::error::invalid review_fixer 'codx'"
  refute_contains "$output" 'first='
}

@test "an empty value is invalid too — silence must not become auto" {
  run "$SCRIPTS/select-review-fixer.sh" ''
  assert_equal "$status" 1
  assert_contains "$output" '::error::invalid review_fixer'
}

@test "a missing argument is invalid" {
  run "$SCRIPTS/select-review-fixer.sh"
  assert_equal "$status" 1
  assert_contains "$output" '::error::invalid review_fixer'
}

@test "the decision also prints to stdout when there is no GITHUB_OUTPUT" {
  unset GITHUB_OUTPUT
  run "$SCRIPTS/select-review-fixer.sh" auto
  assert_equal "$status" 0
  assert_contains "$output" 'first=claude'
  assert_contains "$output" 'fallback_allowed=true'
}

@test "the workflow still defaults review_fixer to auto" {
  # 默认值是「现有调用桩一行不改也不变行为」的全部依据；改掉它，9 个仓库
  # 会在无人知情的情况下换 fixer。
  default="$(awk '
    $0 == "      review_fixer:" { in_input = 1; next }
    in_input && $0 ~ /^        default:/ { sub(/^        default: /, ""); print; exit }
    in_input && $0 ~ /^      [a-z_]+:/   { exit }
  ' "$ITERATE_WORKFLOW")"
  assert_equal "$default" auto
}
