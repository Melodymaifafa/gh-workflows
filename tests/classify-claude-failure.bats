#!/usr/bin/env bats
# scripts/classify-claude-failure.sh —— 把 Claude 的失败分成 quota / business。
# 两种误判的代价不对称：额度失败误判成 business，job 红了、人看一眼就好；业务
# 失败误判成 quota，则是一个本该红的 PR 换个模型再改一轮，把真问题埋进绿勾里。
# 所以下面每条 business 用例都是「必须不换人」的硬约束。

load test_helper/common

classify() {
  printf '%s\n' "$1" | "$SCRIPTS/classify-claude-failure.sh"
}

verdict() {
  printf '%s\n' "$1" | sed -n 's/^class=//p'
}

why() {
  printf '%s\n' "$1" | sed -n 's/^reason=//p'
}

@test "订阅额度用尽 counts as a provider failure" {
  out="$(classify 'error_during_execution true Claude AI usage limit reached|1756089600')"
  assert_equal "$(verdict "$out")" quota
  assert_contains "$(why "$out")" 'usage limit reached'
}

@test "a 429 rate limit counts as a provider failure" {
  out="$(classify 'API Error 429 rate_limit_error: too many requests')"
  assert_equal "$(verdict "$out")" quota
}

@test "an expired or rejected token counts as a provider failure" {
  out="$(classify 'authentication_error: OAuth token has expired')"
  assert_equal "$(verdict "$out")" quota
}

@test "the provider being down counts as a provider failure" {
  out="$(classify 'API Error 529 overloaded_error: service unavailable')"
  assert_equal "$(verdict "$out")" quota
}

@test "matching is case-insensitive" {
  out="$(classify 'FATAL: INSUFFICIENT_QUOTA on this key')"
  assert_equal "$(verdict "$out")" quota
}

@test "a failing test suite is a business failure — no handover" {
  out="$(classify 'error_during_execution true 3 failed, 41 passed in pytest; I could not make them pass')"
  assert_equal "$(verdict "$out")" business
}

@test "a broken build is a business failure — no handover" {
  out="$(classify 'error_during_execution true npm run build exited 1: TS2345 type error in src/app.ts')"
  assert_equal "$(verdict "$out")" business
}

@test "running out of turns is a business failure — no handover" {
  out="$(classify 'error_max_turns true Reached maximum turns without finishing the fix')"
  assert_equal "$(verdict "$out")" business
}

@test "no diagnosable output fails closed to business" {
  out="$(classify '')"
  assert_equal "$(verdict "$out")" business
  assert_contains "$(why "$out")" 'no diagnosable output'
}

@test "whitespace-only output fails closed to business" {
  out="$(classify '   ')"
  assert_equal "$(verdict "$out")" business
}

@test "a missing file fails closed to business instead of erroring" {
  run "$SCRIPTS/classify-claude-failure.sh" "$BATS_TEST_TMPDIR/does-not-exist.txt"
  assert_equal "$status" 0
  assert_contains "$output" 'class=business'
}

@test "the verdict is read from a file when one is given" {
  printf 'API Error 401 unauthorized\n' >"$BATS_TEST_TMPDIR/diag.txt"
  run "$SCRIPTS/classify-claude-failure.sh" "$BATS_TEST_TMPDIR/diag.txt"
  assert_equal "$status" 0
  assert_contains "$output" 'class=quota'
}

@test "the verdict also lands in GITHUB_OUTPUT when the workflow set one" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  : >"$GITHUB_OUTPUT"
  printf 'Claude AI usage limit reached\n' | "$SCRIPTS/classify-claude-failure.sh" >/dev/null
  assert_contains "$(cat "$GITHUB_OUTPUT")" 'class=quota'
}

@test "a review body quoting a quota error is not what the classifier reads" {
  # 分类器只拿到「这次运行的终态字段」，拿不到对话记录 —— 否则 review 正文里
  # 抄一句额度报错就能骗出一次换人。这里守的是调用方的裁剪结果本身。
  out="$(classify 'error_during_execution true the reviewer wrote a comment about handling errors politely')"
  assert_equal "$(verdict "$out")" business
}
