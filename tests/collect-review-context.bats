#!/usr/bin/env bats
# claude-codex-iterate.yml 的 Collect the review context for Codex —— 给 Codex
# 备那份 review 上下文。守两件事：
#   1. 行内评论拉不到就红着停下。本仓库的 review 正文常常只是模板，实质内容全在
#      行内评论里；吞掉一次 API 抖动 = Codex 拿到空 review、不改文件、job 打绿勾
#      收工，链条静默停住。
#   2. 上下文文件不占用固定文件名。这条工作流跑在别人的仓库里，撞上同名的已跟踪
#      文件会被覆盖、再被清理，然后当成 Codex 的改动提交推出去。

load test_helper/common

# 跑 workflow 里那段真代码，gh 换成可控的假货。
collect() {
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/workspace"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'FAKE'
#!/usr/bin/env bash
[ -n "${FAKE_GH_STDOUT:-}" ] && printf '%s' "$FAKE_GH_STDOUT"
exit "${FAKE_GH_EXIT:-0}"
FAKE
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"

  extract_run_block "$ITERATE_WORKFLOW" 'Collect the review context for Codex' \
    >"$BATS_TEST_TMPDIR/collect.sh"

  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  : >"$GITHUB_OUTPUT"

  PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
  GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/workspace" \
  GH_TOKEN=fake REPO=owner/repo PR_NUMBER=10 REVIEW_ID=99 REVIEWED_SHA=deadbeef \
  REVIEW_BODY='Here are some automated review suggestions' \
    bash "$BATS_TEST_TMPDIR/collect.sh"
}

# 这一步写进 GITHUB_OUTPUT 的上下文文件路径，后面两步靠它找文件。
context_file() {
  sed -n 's/^file=//p' "$BATS_TEST_TMPDIR/github_output"
}

@test "failing to read the inline comments stops the round instead of running Codex blind" {
  FAKE_GH_EXIT=1 run collect
  assert_equal "$status" 1
  assert_contains "$output" '::error::'
  assert_contains "$output" 'incomplete review'
}

@test "a round with no inline comments is not a failure" {
  FAKE_GH_EXIT=0 FAKE_GH_STDOUT='' run collect
  assert_equal "$status" 0
  assert_contains "$(cat "$(context_file)")" 'automated review suggestions'
}

@test "the inline comments land in the context file" {
  FAKE_GH_EXIT=0 FAKE_GH_STDOUT='- scripts/x.sh:12 — this swallows the error' run collect
  assert_equal "$status" 0
  assert_contains "$(cat "$(context_file)")" 'this swallows the error'
}

@test "the context file never claims a fixed name in the caller's checkout" {
  mkdir -p "$BATS_TEST_TMPDIR/workspace"
  printf 'a file the caller repo already tracks\n' \
    >"$BATS_TEST_TMPDIR/workspace/codex-review-context.md"

  FAKE_GH_EXIT=0 FAKE_GH_STDOUT='' run collect

  assert_equal "$status" 0
  assert_contains "$(cat "$BATS_TEST_TMPDIR/workspace/codex-review-context.md")" 'already tracks'
  refute_contains "$(context_file)" '/codex-review-context.md'
}
