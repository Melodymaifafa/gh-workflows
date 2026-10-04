#!/usr/bin/env bats
# 每周探新 Opus：一样不推、不一样推一次、探测失败不误报。
# 「钉的是什么」一律从真的 workflow 文件读（不在测试里复制一份清单——两边迟早各改各的），
# 所以 claude_model 的默认值哪天换了，这些测试跟着换，不用改。

# 字面量 ${{ }} 是 step 名；bats 每个 @test 是子 shell。
# shellcheck disable=SC2016,SC2030,SC2031

load test_helper/common

WF=.github/workflows/opus-model-probe.yml
PROBE=scripts/probe-latest-opus.sh
RUNS_ROUTE='repos/o/r/actions/workflows/opus-model-probe.yml/runs?status=success&per_page=1'

# pinned_now：仓库现在钉的那个值，独立于被测脚本的读法取一遍。
pinned_now() {
  grep -A 12 '^      claude_model:' "$REPO_ROOT/.github/workflows/codex-approved-merge.yml" |
    sed -n 's/^        default: //p' | head -n 1
}

# model <id> <created_at> [display_name]
model() {
  jq -cn --arg id "$1" --arg at "$2" --arg name "${3:-$1}" \
    '{id: $id, created_at: $at, display_name: $name, type: "model"}'
}

# models_json <model-json>...：/v1/models 的响应，写成文件，打印路径。
models_json() {
  local f="$BATS_TEST_TMPDIR/models-$RANDOM.json"
  printf '%s\n' "$@" | jq -s '{data: ., has_more: false}' >"$f"
  echo "$f"
}

# probe：按真跑时的样子执行脚本（假 curl / 假 gh 已在 PATH 上）。
probe() {
  bash --noprofile --norc "$REPO_ROOT/$PROBE"
}

setup() {
  setup_fake_env
  export REPO=o/r GH_TOKEN=t
  export PUSHOVER_TOKEN=pt PUSHOVER_USER=pu
  export FORCE_NOTIFY=false
  unset MODELS_JSON NOTIFY_WATERMARK CLAUDE_CODE_OAUTH_TOKEN || true
}

@test "钉的就是最新的：什么都不推" {
  MODELS_JSON="$(models_json \
    "$(model "$(pinned_now)" 2026-09-21T16:24:00Z 'Claude Opus 新')" \
    "$(model claude-opus-5 2026-07-24T00:00:00Z 'Claude Opus 5')")"
  export MODELS_JSON

  run probe
  assert_equal "$status" 0
  assert_contains "$output" '钉的就是最新的'
  refute_called pushover.net
}

@test "出了更新的 Opus：推一条，正文带新旧两个名字" {
  MODELS_JSON="$(models_json \
    "$(model claude-opus-6 2026-11-02T00:00:00Z 'Claude Opus 6')" \
    "$(model "$(pinned_now)" 2026-09-21T16:24:00Z 'Claude Opus 5.5')")"
  export MODELS_JSON
  fake_route "$RUNS_ROUTE" '{"workflow_runs":[{"run_started_at":"2026-10-26T01:17:00Z"}]}'

  run probe
  assert_equal "$status" 0
  assert_called pushover.net 1
  body="$(fake_last_body pushover.net)"
  assert_contains "$body" claude-opus-6
  assert_contains "$body" "$(pinned_now)"
}

@test "同一个结论第二次：不再推" {
  MODELS_JSON="$(models_json \
    "$(model claude-opus-6 2026-11-02T00:00:00Z 'Claude Opus 6')" \
    "$(model "$(pinned_now)" 2026-09-21T16:24:00Z 'Claude Opus 5.5')")"
  export MODELS_JSON
  # 上一次成功探测在这个模型发布之后 —— 说明那一轮已经推过了。
  fake_route "$RUNS_ROUTE" '{"workflow_runs":[{"run_started_at":"2026-11-09T01:17:00Z"}]}'

  run probe
  assert_equal "$status" 0
  assert_contains "$output" '已经推过'
  refute_called pushover.net
}

@test "新 Opus 的发布时间接口填了 1970 年（不详）：照样认出它、照样推，不当成推过" {
  # 接口按新→旧排；发布时间不详时文档允许填纪元时间。按日期自己排会挑回旧的那个。
  MODELS_JSON="$(models_json \
    "$(model claude-opus-6 1970-01-01T00:00:00Z 'Claude Opus 6')" \
    "$(model "$(pinned_now)" 2026-09-21T16:24:00Z 'Claude Opus 5.5')")"
  export MODELS_JSON
  fake_route "$RUNS_ROUTE" '{"workflow_runs":[{"run_started_at":"2026-11-09T01:17:00Z"}]}'

  run probe
  assert_equal "$status" 0
  assert_called pushover.net 1
  body="$(fake_last_body pushover.net)"
  assert_contains "$body" claude-opus-6
  assert_contains "$body" 发布时间未知
  refute_contains "$body" 1970
  refute_contains "$body" 下周不会再推
}

@test "钉的就是最新的，但它发布时间不详：也什么都不推" {
  MODELS_JSON="$(models_json \
    "$(model "$(pinned_now)" 1970-01-01T00:00:00Z 'Claude Opus 新')" \
    "$(model claude-opus-5 2026-07-24T00:00:00Z 'Claude Opus 5')")"
  export MODELS_JSON

  run probe
  assert_equal "$status" 0
  assert_contains "$output" '钉的就是最新的'
  refute_called pushover.net
}

@test "第一次就跑（没有任何成功的 run）：推一条" {
  MODELS_JSON="$(models_json "$(model claude-opus-6 2026-11-02T00:00:00Z 'Claude Opus 6')")"
  export MODELS_JSON
  fake_route "$RUNS_ROUTE" '{"workflow_runs":[]}'

  run probe
  assert_equal "$status" 0
  assert_called pushover.net 1
}

@test "手动勾了 force：推过也再推" {
  MODELS_JSON="$(models_json \
    "$(model claude-opus-6 2026-11-02T00:00:00Z 'Claude Opus 6')" \
    "$(model "$(pinned_now)" 2026-09-21T16:24:00Z 'Claude Opus 5.5')")"
  export MODELS_JSON FORCE_NOTIFY=true
  fake_route "$RUNS_ROUTE" '{"workflow_runs":[{"run_started_at":"2026-11-09T01:17:00Z"}]}'

  run probe
  assert_equal "$status" 0
  assert_called pushover.net 1
}

@test "探测失败（接口报错）：红着停下，不推" {
  # /v1/models 回了一个错误对象，不是模型列表。
  f="$BATS_TEST_TMPDIR/err.json"
  echo '{"type":"error","error":{"type":"authentication_error","message":"invalid"}}' >"$f"
  export MODELS_JSON="$f"

  run probe
  [ "$status" -ne 0 ]
  assert_contains "$output" '::error::'
  refute_called pushover.net
}

@test "探测失败（响应不是 JSON）：红着停下，不推" {
  f="$BATS_TEST_TMPDIR/garbage.json"
  echo '<html>502 Bad Gateway</html>' >"$f"
  export MODELS_JSON="$f"

  run probe
  [ "$status" -ne 0 ]
  refute_called pushover.net
}

@test "列表里只有别的家族（没有 Opus）：红着停下，不推" {
  MODELS_JSON="$(models_json "$(model claude-fable-5-1 2026-08-28T00:00:00Z 'Claude Fable 5.1')")"
  export MODELS_JSON

  run probe
  [ "$status" -ne 0 ]
  refute_called pushover.net
}

@test "读不到自己的 run 历史：当没推过，宁可重复一条也不漏掉新模型" {
  MODELS_JSON="$(models_json "$(model claude-opus-6 2026-11-02T00:00:00Z 'Claude Opus 6')")"
  export MODELS_JSON
  # 第一次跑时这个接口会 404（workflow 刚进默认分支，还没有 run 记录）。
  fake_route_fail "$RUNS_ROUTE" 1 '{"message":"Not Found"}'

  run probe
  assert_equal "$status" 0
  assert_contains "$output" '::warning::'
  assert_called pushover.net 1
}

@test "Pushover 挂了：红着停下（水位不前进，下一轮重试）" {
  MODELS_JSON="$(models_json "$(model claude-opus-6 2026-11-02T00:00:00Z 'Claude Opus 6')")"
  export MODELS_JSON
  fake_route "$RUNS_ROUTE" '{"workflow_runs":[]}'
  echo 22 >"$FAKE_GH_DIR/curl.exit"

  run probe
  [ "$status" -ne 0 ]
  assert_contains "$output" 'Pushover'
  # 没推出去就不许在 summary 里写「已推送」。
  refute_contains "$(cat "$GITHUB_STEP_SUMMARY")" 已推送通知
}

@test "claude_model 默认值读得出来，而且是 Opus 档的字面 id" {
  pinned="$(pinned_now)"
  [ -n "$pinned" ]
  assert_contains "$pinned" claude-opus-
  # 两个 workflow 必须钉同一个值，否则通知里的「钉的是什么」没有唯一答案。
  other="$(grep -A 12 '^      claude_model:' "$REPO_ROOT/.github/workflows/claude-codex-iterate.yml" |
    sed -n 's/^        default: //p' | head -n 1)"
  assert_equal "$other" "$pinned"
}

@test "workflow 把该给的都给了这一步，而且跑的是仓库里那个脚本" {
  keys="$(step_env_keys "$WF" 'Probe the newest Opus')"
  assert_contains "$keys" CLAUDE_CODE_OAUTH_TOKEN
  assert_contains "$keys" PUSHOVER_TOKEN
  assert_contains "$keys" PUSHOVER_USER
  assert_contains "$keys" GH_TOKEN
  assert_contains "$(cat "$REPO_ROOT/$WF")" "run: ./$PROBE"
  # 保活的 workflow 文件名必须是自己，写错了就是给别的定时任务续命。
  assert_contains "$(extract_run_block "$REPO_ROOT/$WF" 'Keep the schedule alive')" \
    'actions/workflows/opus-model-probe.yml/enable'
}
