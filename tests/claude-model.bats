#!/usr/bin/env bats
# Claude 用哪个模型、想多深：默认值钉死在可复用工作流里，永远是 Opus 及以上；
# 填 Sonnet / Haiku 或拼错思考力度直接红；总结评论写出实际跑的模型。
# 背景：不钉的话 action 用账号默认模型，那曾经是 Sonnet，静静跑了几周没人发现。

# 字面量 ${{ }} 是要比对的文本；bats 每个 @test 是子 shell。
# shellcheck disable=SC2016,SC2030,SC2031,SC2155

load test_helper/common

WF=.github/workflows/claude-codex-iterate.yml
MERGE_WF=.github/workflows/codex-approved-merge.yml
SDK="$FIXTURES_DIR/sdk"

# input_default <workflow> <input>：读 workflow_call 里某个 input 的 default。
input_default() {
  awk -v want="      $2:" '
    $0 == want { f = 1; next }
    f && /^        default:/ { sub(/^        default: */, ""); print; exit }
  ' "$REPO_ROOT/$1"
}

setup() {
  setup_fake_env
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp"
  mkdir -p "$RUNNER_TEMP"
}

# ---------- 默认值：Opus 及以上，xhigh ----------

@test "workflow: the Claude fixer defaults to an Opus-tier model at xhigh effort" {
  model="$(input_default "$WF" claude_model)"
  assert_contains "$model" opus
  refute_contains "$model" sonnet
  refute_contains "$model" haiku
  assert_equal "$(input_default "$WF" claude_effort)" xhigh
  step="$(awk '/^      - uses: anthropics\/claude-code-action@v1/{f=1} f&&/^      - name:/{exit} f' "$REPO_ROOT/$WF")"
  assert_contains "$step" '--model ${{ inputs.claude_model }}'
  assert_contains "$step" '--effort ${{ inputs.claude_effort }}'
}

@test "workflow: the Claude fallback reviewer pins the same Opus-tier default" {
  model="$(input_default "$MERGE_WF" claude_model)"
  assert_contains "$model" opus
  refute_contains "$model" sonnet
  refute_contains "$model" haiku
  assert_equal "$(input_default "$MERGE_WF" claude_effort)" xhigh
  job="$(awk '/^  claude-review:/{on=1} /^  resolve-conflict:/{exit} on' "$REPO_ROOT/$MERGE_WF")"
  assert_contains "$job" '--model ${{ inputs.claude_model }}'
  assert_contains "$job" '--effort ${{ inputs.claude_effort }}'
}

# ---------- 先验：拼错 / 降级直接红 ----------

# 白名单，不是黑名单：default（账号默认）和 opusplan（执行时用 Sonnet）名字里都没有
# Sonnet，黑名单拦不住它们（Codex P2 on PR #18）。
@test "resolve: anything but an explicit Opus-or-above selector is refused before Claude runs" {
  export RUNTIME=shell VERIFY_OVERRIDE='' TOOLS_OVERRIDE='' CLAUDE_EFFORT=xhigh VERIFY_ISOLATION=auto
  for model in claude-sonnet-5 sonnet claude-haiku-4-5 Haiku default opusplan best gpt-5; do
    export CLAUDE_MODEL="$model"
    run run_block "$WF" "Resolve runtime defaults"
    assert_equal "$status" 1
    assert_contains "$output" 'not an explicit Opus-or-above selector'
  done
}

@test "resolve: explicit Opus-or-above selectors pass" {
  export RUNTIME=shell VERIFY_OVERRIDE='' TOOLS_OVERRIDE='' CLAUDE_EFFORT=xhigh VERIFY_ISOLATION=auto
  for model in opus 'opus[1m]' fable claude-opus-5-5 'claude-opus-5-5[1m]' claude-fable-5-1; do
    export CLAUDE_MODEL="$model"
    run run_block "$WF" "Resolve runtime defaults"
    assert_equal "$status" 0
  done
}

@test "resolve: an empty model or an unknown effort level is refused" {
  export RUNTIME=shell VERIFY_OVERRIDE='' TOOLS_OVERRIDE='' VERIFY_ISOLATION=auto
  export CLAUDE_MODEL='' CLAUDE_EFFORT=xhigh
  run run_block "$WF" "Resolve runtime defaults"
  assert_equal "$status" 1
  assert_contains "$output" 'claude_model is empty'

  export CLAUDE_MODEL=claude-opus-5-5 CLAUDE_EFFORT=maximum
  run run_block "$WF" "Resolve runtime defaults"
  assert_equal "$status" 1
  assert_contains "$output" 'not one of low, medium, high, xhigh, max'
}

@test "resolve: every documented effort level passes with an Opus model" {
  export RUNTIME=shell VERIFY_OVERRIDE='' TOOLS_OVERRIDE='' CLAUDE_MODEL=claude-opus-5-5 VERIFY_ISOLATION=auto
  for effort in low medium high xhigh max; do
    export CLAUDE_EFFORT="$effort"
    run run_block "$WF" "Resolve runtime defaults"
    assert_equal "$status" 0
  done
}

# ---------- 总结评论写出实际跑的模型 ----------

@test "claude: the summary comment names the model that actually ran" {
  export STRUCTURED='{"pushed":true,"fixed":2,"skipped":1,"summary":"修了 2 条，跳过 1 条"}'
  export PUSHED=true REPO=o/r PR_NUMBER=7 GH_TOKEN=t GH_HOST=127.0.0.1
  export EXEC_FILE="$SDK/exec-success-structured.json" CLAUDE_MODEL=claude-opus-5-5 CLAUDE_EFFORT=xhigh

  run run_step "$WF" "Post the Claude summary comment"

  assert_equal "$status" 0
  # 写的是执行记录里的名字，不是配置里抄的：两者不一样时才看得出默认值悄悄变了
  assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" '模型：claude-sonnet-5 · 思考力度：xhigh'
}

@test "claude: without an execution record the summary falls back to the configured model" {
  export STRUCTURED='{"pushed":false,"fixed":0,"skipped":1,"summary":"修了 0 条，跳过 1 条"}'
  export PUSHED='' REPO=o/r PR_NUMBER=7 GH_TOKEN=t GH_HOST=127.0.0.1
  export EXEC_FILE='' CLAUDE_MODEL=claude-opus-5-5 CLAUDE_EFFORT=xhigh

  run run_step "$WF" "Post the Claude summary comment"

  assert_equal "$status" 0
  assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" '模型：claude-opus-5-5 · 思考力度：xhigh'
}

# ---------- 代审那条路同一段先验（Codex P2 on PR #18） ----------

# model_guard_block <workflow>：两段 case 块（模型、思考力度），从 case "$CLAUDE_MODEL" 起到第二个 esac 止。
model_guard_block() {
  awk '
    /case "\$CLAUDE_MODEL" in/ { on = 1 }
    on { print }
    on && /^ *esac$/ { if (++n == 2) exit }
  ' "$REPO_ROOT/$1"
}

@test "merge: the fallback review refuses non-Opus selectors and unknown effort before Claude runs" {
  export CLAUDE_EFFORT=xhigh
  for model in claude-sonnet-5 sonnet claude-haiku-4-5 default opusplan ''; do
    export CLAUDE_MODEL="$model"
    run run_block "$MERGE_WF" "Check the review model and effort"
    assert_equal "$status" 1
  done
  export CLAUDE_MODEL=claude-opus-5-5 CLAUDE_EFFORT=ultra
  run run_block "$MERGE_WF" "Check the review model and effort"
  assert_equal "$status" 1
  assert_contains "$output" 'not one of low, medium, high, xhigh, max'
  export CLAUDE_EFFORT=xhigh
  run run_block "$MERGE_WF" "Check the review model and effort"
  assert_equal "$status" 0
}

# 两处是逐行副本，这一条盯着它们不许各改各的；改一处就得改另一处。
@test "merge: the guard is the very same case block as the fixer's" {
  fixer="$(model_guard_block "$WF")"
  reviewer="$(model_guard_block "$MERGE_WF")"
  [ -n "$fixer" ] || { echo 'no model guard found in the iterate workflow' >&2; return 1; }
  assert_equal "$reviewer" "$fixer"
}

# round-cap-judge 在 iterate 红了时也跑，那边的先验拦不住它，所以有第三份同样的块。
judge_guard_block() {
  awk '/^  round-cap-judge:/{on=1} /^  round-cap-park:/{exit} on' "$REPO_ROOT/$WF" | awk '
    /case "\$CLAUDE_MODEL" in/ { on = 1 }
    on { print }
    on && /^ *esac$/ { if (++n == 2) exit }
  '
}

@test "judge: the round-cap judge carries the very same guard, before Claude runs" {
  fixer="$(model_guard_block "$WF")"
  assert_equal "$(judge_guard_block)" "$fixer"
  job="$(awk '/^  round-cap-judge:/{on=1} /^  round-cap-park:/{exit} on' "$REPO_ROOT/$WF")"
  guard_at="$(awk '/- name: Check the judge model and effort/{print NR; exit}' <<<"$job")"
  judge_at="$(awk '/- name: Claude judges the leftover findings$/{print NR; exit}' <<<"$job")"
  [ -n "$guard_at" ] && [ -n "$judge_at" ] || { echo 'guard or judge step missing' >&2; return 1; }
  [ "$guard_at" -lt "$judge_at" ] || { echo "guard at $guard_at is after judge at $judge_at" >&2; return 1; }
}

@test "judge: the guard refuses a Sonnet model before the judge runs" {
  export CLAUDE_MODEL=claude-sonnet-5 CLAUDE_EFFORT=xhigh
  run run_block "$WF" "Check the judge model and effort"
  assert_equal "$status" 1
  export CLAUDE_MODEL=claude-opus-5-5
  run run_block "$WF" "Check the judge model and effort"
  assert_equal "$status" 0
}

# 解冲突那个 job 是第四份同样的块：冲突解完同样会被自动合并，降级模型不能混进来。
@test "merge: the conflict resolver carries the very same guard, before Claude runs" {
  job="$(awk '/^  resolve-conflict:/{on=1} on' "$REPO_ROOT/$MERGE_WF")"
  resolver="$(awk '
    /case "\$CLAUDE_MODEL" in/ { on = 1 }
    on { print }
    on && /^ *esac$/ { if (++n == 2) exit }
  ' <<<"$job")"
  assert_equal "$resolver" "$(model_guard_block "$WF")"
  guard_at="$(awk '/- name: Check the resolver model and effort/{print NR; exit}' <<<"$job")"
  claude_at="$(awk '/- name: Claude resolves the conflicts$/{print NR; exit}' <<<"$job")"
  [ -n "$guard_at" ] && [ -n "$claude_at" ] || { echo 'guard or resolver step missing' >&2; return 1; }
  [ "$guard_at" -lt "$claude_at" ] || { echo "guard at $guard_at is after Claude at $claude_at" >&2; return 1; }
  export CLAUDE_MODEL=claude-sonnet-5 CLAUDE_EFFORT=xhigh
  run run_block "$MERGE_WF" "Check the resolver model and effort"
  assert_equal "$status" 1
}

# 先验必须排在 Claude 那一步前面，否则 action 已经带着错值启动了。
@test "merge: the guard runs before the Claude review step" {
  job="$(awk '/^  claude-review:/{on=1} /^  resolve-conflict:/{exit} on' "$REPO_ROOT/$MERGE_WF")"
  guard_at="$(awk '/- name: Check the review model and effort/{print NR; exit}' <<<"$job")"
  review_at="$(awk '/- name: Claude review$/{print NR; exit}' <<<"$job")"
  [ -n "$guard_at" ] && [ -n "$review_at" ] || { echo 'guard or review step missing' >&2; return 1; }
  [ "$guard_at" -lt "$review_at" ] || { echo "guard at $guard_at is after review at $review_at" >&2; return 1; }
}
