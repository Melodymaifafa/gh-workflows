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
  job="$(awk '/^  claude-review:/{on=1} on' "$REPO_ROOT/$MERGE_WF")"
  assert_contains "$job" '--model ${{ inputs.claude_model }}'
  assert_contains "$job" '--effort ${{ inputs.claude_effort }}'
}

# ---------- 先验：拼错 / 降级直接红 ----------

@test "resolve: a Sonnet or Haiku model is refused before Claude runs" {
  export RUNTIME=shell VERIFY_OVERRIDE='' TOOLS_OVERRIDE='' CLAUDE_EFFORT=xhigh
  for model in claude-sonnet-5 sonnet claude-haiku-4-5 Haiku; do
    export CLAUDE_MODEL="$model"
    run run_block "$WF" "Resolve runtime defaults"
    assert_equal "$status" 1
    assert_contains "$output" 'below Opus'
  done
}

@test "resolve: an empty model or an unknown effort level is refused" {
  export RUNTIME=shell VERIFY_OVERRIDE='' TOOLS_OVERRIDE=''
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
  export RUNTIME=shell VERIFY_OVERRIDE='' TOOLS_OVERRIDE='' CLAUDE_MODEL=claude-opus-5-5
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
