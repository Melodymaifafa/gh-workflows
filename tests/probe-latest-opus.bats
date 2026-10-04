#!/usr/bin/env bats
# 每周探新 Opus：一样不推、不一样推一次、探测失败不误报。
# 「推过没有」认的是模型本身（推成功那轮留下的凭据，以模型 id 命名），不认发布时间 ——
# 认时间的那一版会把「发布日期比上次探测还早的新模型」判成推过了，然后永远不再提醒。
# 「钉的是什么」一律从真的 workflow 文件读（不在测试里复制一份清单——两边迟早各改各的），
# 所以 claude_model 的默认值哪天换了，这些测试跟着换，不用改。

# 字面量 ${{ }} 是 step 名和 workflow 表达式；bats 每个 @test 是子 shell。
# shellcheck disable=SC2016,SC2030,SC2031

load test_helper/common

WF=.github/workflows/opus-model-probe.yml
PROBE=scripts/probe-latest-opus.sh
# 认时间的那一版读的是这条路由。留在这里是为了挡回头路：谁把判断改回「比时间」，
# 下面那条复现测试就会用这份过期水位重现原来的 bug，然后红。
STALE_RUNS_ROUTE='repos/o/r/actions/workflows/opus-model-probe.yml/runs?status=success&per_page=1'

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

# model_without_created_at <id> [display_name]：接口压根没给发布时间的那种条目。
model_without_created_at() {
  jq -cn --arg id "$1" --arg name "${2:-$1}" '{id: $id, display_name: $name, type: "model"}'
}

# models_json <model-json>...：/v1/models 的响应，写成文件，打印路径。
models_json() {
  local f="$BATS_TEST_TMPDIR/models-$RANDOM.json"
  printf '%s\n' "$@" | jq -s '{data: ., has_more: false}' >"$f"
  echo "$f"
}

# 凭据 = 一个叫 opus-notified-<模型 id> 的 artifact，脚本按名字精确查。
ledger_route() { echo "repos/o/r/actions/artifacts?name=opus-notified-$1&per_page=100"; }

# ledger_has <被查的模型> [凭据的名字] [expired]：接口回一条凭据。
# 第二、三个参数是为了造「接口把 name= 过滤忽略了」「凭据过期了」这两种歪的回答。
ledger_has() {
  local asked="$1" named="opus-notified-${2:-$1}" expired="${3:-false}"
  fake_route "$(ledger_route "$asked")" \
    "$(jq -cn --arg n "$named" --argjson e "$expired" \
      '{total_count: 1, artifacts: [{id: 11, name: $n, expired: $e}]}')"
}

# ledger_empty <模型>：没推过 —— 一条凭据都没有。
ledger_empty() { fake_route "$(ledger_route "$1")" '{"total_count":0,"artifacts":[]}'; }

# probe：按真跑时的样子执行脚本（假 curl / 假 gh 已在 PATH 上）。
probe() {
  bash --noprofile --norc "$REPO_ROOT/$PROBE"
}

setup() {
  setup_fake_env
  export REPO=o/r GH_TOKEN=t
  export PUSHOVER_TOKEN=pt PUSHOVER_USER=pu
  export FORCE_NOTIFY=false
  export RUNNER_TEMP="$BATS_TEST_TMPDIR"
  unset MODELS_JSON CLAUDE_CODE_OAUTH_TOKEN || true
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
  ledger_empty claude-opus-6

  run probe
  assert_equal "$status" 0
  assert_called pushover.net 1
  body="$(fake_last_body pushover.net)"
  assert_contains "$body" claude-opus-6
  assert_contains "$body" "$(pinned_now)"
}

@test "新模型的发布日期比上一次探测还早：照样推（认时间的那一版会在这里把它咽掉）" {
  # 复现审核退回的那个洞：模型 2026-11-02 发布，上一次成功探测是 2026-11-09 —— 比它晚。
  # 发布时间不等于「这个令牌第一次看见它」的时间（灰度、列表滞后），拿它当依据就会
  # 对一条从没推过的新模型说「已经推过」，然后每一轮都这么说，永远不提醒。
  MODELS_JSON="$(models_json \
    "$(model claude-opus-6 2026-11-02T00:00:00Z 'Claude Opus 6')" \
    "$(model "$(pinned_now)" 2026-09-21T16:24:00Z 'Claude Opus 5.5')")"
  export MODELS_JSON
  ledger_empty claude-opus-6
  # 认时间的那一版会读到这份过期水位，然后判「推过了」、一条都不推。
  fake_route "$STALE_RUNS_ROUTE" '{"workflow_runs":[{"run_started_at":"2026-11-09T01:17:00Z"}]}'

  run probe
  assert_equal "$status" 0
  refute_contains "$output" '已经推过'
  assert_called pushover.net 1
  assert_contains "$(fake_last_body pushover.net)" claude-opus-6
  # 去重不许再碰 run 历史：碰了就是又回到按时间判断。
  refute_called 'opus-model-probe.yml/runs?'
}

@test "同一个模型第二次（凭据在）：不再推" {
  MODELS_JSON="$(models_json \
    "$(model claude-opus-6 2026-11-02T00:00:00Z 'Claude Opus 6')" \
    "$(model "$(pinned_now)" 2026-09-21T16:24:00Z 'Claude Opus 5.5')")"
  export MODELS_JSON
  ledger_has claude-opus-6

  run probe
  assert_equal "$status" 0
  assert_contains "$output" '推过了'
  refute_called pushover.net
}

@test "凭据过期了（GitHub 回收）：按没推过，再推一条" {
  MODELS_JSON="$(models_json \
    "$(model claude-opus-6 2026-11-02T00:00:00Z 'Claude Opus 6')" \
    "$(model "$(pinned_now)" 2026-09-21T16:24:00Z 'Claude Opus 5.5')")"
  export MODELS_JSON
  ledger_has claude-opus-6 claude-opus-6 true

  run probe
  assert_equal "$status" 0
  assert_called pushover.net 1
}

@test "回来的凭据是别的模型的（接口没按名字过滤）：不当成这条推过了" {
  MODELS_JSON="$(models_json \
    "$(model claude-opus-6 2026-11-02T00:00:00Z 'Claude Opus 6')" \
    "$(model "$(pinned_now)" 2026-09-21T16:24:00Z 'Claude Opus 5.5')")"
  export MODELS_JSON
  ledger_has claude-opus-6 claude-opus-5

  run probe
  assert_equal "$status" 0
  assert_called pushover.net 1
}

@test "新 Opus 的发布时间接口填了 1970 年（不详）：照样认出它、照样推一条" {
  # 接口按新→旧排；发布时间不详时文档允许填纪元时间。按日期自己排会挑回旧的那个。
  MODELS_JSON="$(models_json \
    "$(model claude-opus-6 1970-01-01T00:00:00Z 'Claude Opus 6')" \
    "$(model "$(pinned_now)" 2026-09-21T16:24:00Z 'Claude Opus 5.5')")"
  export MODELS_JSON
  ledger_empty claude-opus-6

  run probe
  assert_equal "$status" 0
  assert_called pushover.net 1
  body="$(fake_last_body pushover.net)"
  assert_contains "$body" claude-opus-6
  assert_contains "$body" 发布时间未知
  refute_contains "$body" 1970
}

@test "接口压根没给发布时间：照样推，不红着停下" {
  MODELS_JSON="$(models_json \
    "$(model_without_created_at claude-opus-6 'Claude Opus 6')" \
    "$(model "$(pinned_now)" 2026-09-21T16:24:00Z 'Claude Opus 5.5')")"
  export MODELS_JSON
  ledger_empty claude-opus-6

  run probe
  assert_equal "$status" 0
  assert_called pushover.net 1
  assert_contains "$(fake_last_body pushover.net)" 发布时间未知
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

@test "手动勾了 force：推过也再推，而且压根不去查凭据" {
  MODELS_JSON="$(models_json \
    "$(model claude-opus-6 2026-11-02T00:00:00Z 'Claude Opus 6')" \
    "$(model "$(pinned_now)" 2026-09-21T16:24:00Z 'Claude Opus 5.5')")"
  export MODELS_JSON FORCE_NOTIFY=true
  ledger_has claude-opus-6

  run probe
  assert_equal "$status" 0
  assert_called pushover.net 1
  refute_called 'actions/artifacts'
}

@test "查不到凭据列表：当没推过，宁可重复一条也不漏掉新模型" {
  MODELS_JSON="$(models_json "$(model claude-opus-6 2026-11-02T00:00:00Z 'Claude Opus 6')")"
  export MODELS_JSON
  # 第一次跑、令牌权限不够、接口抖，都是这条路。
  fake_route_fail "$(ledger_route claude-opus-6)" 1 '{"message":"Not Found"}'

  run probe
  assert_equal "$status" 0
  assert_contains "$output" '::warning::'
  assert_called pushover.net 1
}

@test "凭据列表回了个认不出的答案：当没推过，不许静默" {
  MODELS_JSON="$(models_json "$(model claude-opus-6 2026-11-02T00:00:00Z 'Claude Opus 6')")"
  export MODELS_JSON
  fake_route "$(ledger_route claude-opus-6)" '{"message":"Bad credentials"}'

  run probe
  assert_equal "$status" 0
  assert_called pushover.net 1
}

@test "推成功了：把凭据的名字和文件交给上传那一步" {
  MODELS_JSON="$(models_json "$(model claude-opus-6 2026-11-02T00:00:00Z 'Claude Opus 6')")"
  export MODELS_JSON
  ledger_empty claude-opus-6

  run probe
  assert_equal "$status" 0
  assert_equal "$(step_output notified_artifact)" opus-notified-claude-opus-6
  marker="$(step_output notified_marker)"
  [ -f "$marker" ]
  assert_contains "$(cat "$marker")" claude-opus-6
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

@test "Pushover 挂了：红着停下，不留凭据（下一轮会重试）" {
  MODELS_JSON="$(models_json "$(model claude-opus-6 2026-11-02T00:00:00Z 'Claude Opus 6')")"
  export MODELS_JSON
  ledger_empty claude-opus-6
  echo 22 >"$FAKE_GH_DIR/curl.exit"

  run probe
  [ "$status" -ne 0 ]
  assert_contains "$output" 'Pushover'
  # 没推出去就不许留凭据（留了下一轮就把这条当推过了），也不许在 summary 里写「已推送」。
  refute_contains "$(cat "$GITHUB_OUTPUT")" notified_artifact
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

@test "留凭据那一步只在推成功后跑，名字和文件都用脚本交出来的那两个" {
  wf="$(cat "$REPO_ROOT/$WF")"
  assert_contains "$wf" 'id: probe'
  assert_contains "$wf" 'uses: actions/upload-artifact@v4'
  # 名字写死在 workflow 里就会跟脚本算的那个错开，所以只准用脚本交出来的。
  assert_contains "$wf" 'name: ${{ steps.probe.outputs.notified_artifact }}'
  assert_contains "$wf" 'path: ${{ steps.probe.outputs.notified_marker }}'
  assert_contains "$wf" "if: steps.probe.outputs.notified_artifact != ''"
  # 查凭据要 actions 读权限，保活要写权限，写包含读。
  assert_contains "$wf" 'actions: write'
}
