#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats 每个 @test 是子 shell
# claude-codex-iterate.yml 的 Codex 接管路径：意见怎么交到 Codex 手上，以及
# 「Claude 这轮没跑成」之后谁来下结论。守三件事：
#   1. 拿不到 review 就红着停下 —— 空 review 会让 Codex 不改任何文件、job 打
#      绿勾收工，链条静默停住。
#   2. 交出去的是 Gate 预取的 .review/findings.md（已进 .git/info/exclude），
#      不是调用方仓库根目录里一个写死的文件名。
#   3. 只有服务商侧失败才换人；业务失败红着停下，而且一定有人发告警。

load test_helper/common

WF=.github/workflows/claude-codex-iterate.yml
H=1a7e81f6b5f27f0a1dbc33c6fafda1bb86f1483d
CODEX='chatgpt-codex-connector[bot]'

setup() {
  setup_fake_env
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp"
  mkdir -p "$RUNNER_TEMP/fixer-scripts" "$BATS_TEST_TMPDIR/work"
  cp "$SCRIPTS/classify-claude-failure.sh" "$RUNNER_TEMP/fixer-scripts/"
  cd "$BATS_TEST_TMPDIR/work" || return
  export REPO=o/r PR_NUMBER=7 GH_TOKEN=test-token
  export PUSHOVER_TOKEN=pt PUSHOVER_USER=pu
  run_block "$WF" "Define pr-guard helpers" >/dev/null
  fake_route "repos/o/r/issues/7/comments?per_page=100" '[]'
}

# ---------- 意见怎么交到 Codex 手上 ----------

@test "takeover: the gate stops the round when the inline comments cannot be read" {
  export REVIEW_ID=4001 REVIEW_COMMIT="$H" REVIEW_LOGIN="$CODEX" REVIEW_ASSOC=NONE
  export REVIEW_BODY='### 💡 Codex Review' MAX_FIX_ROUNDS=5
  fake_route repos/o/r/pulls/7 "{\"head\":{\"sha\":\"$H\"}}"
  fake_route repos/o/r/pulls/7/reviews/4001 "$(gh_review 4001 "$CODEX" NONE "$H" 'body')"
  fake_route_fail "repos/o/r/pulls/7/reviews/4001/comments?per_page=100" 1

  run run_block "$WF" "Gate the fix round"

  [ "$status" -ne 0 ]
  refute_contains "$(cat "$GITHUB_OUTPUT")" 'run=true'
}

@test "takeover: Codex is never handed a missing or empty review" {
  run run_block "$WF" "Point Codex at the prefetched review"
  assert_equal "$status" 1
  assert_contains "$output" '::error::'
  assert_contains "$output" 'incomplete review'

  mkdir -p .review
  : >.review/findings.md
  run run_block "$WF" "Point Codex at the prefetched review"
  assert_equal "$status" 1
}

@test "takeover: the handoff names the excluded prefetch, not a file in the caller's checkout" {
  printf 'a file the caller repo already tracks\n' >codex-review-context.md
  mkdir -p .review
  printf '## 行内评论\n\n- scripts/x.sh:12 — this swallows the error\n' >.review/findings.md

  run run_block "$WF" "Point Codex at the prefetched review"

  assert_equal "$status" 0
  assert_equal "$(step_output file)" .review/findings.md
  assert_contains "$(cat codex-review-context.md)" 'already tracks'
}

# ---------- 谁来下结论 ----------

# 这一步在 review_fixer 允许换人时把结论让给 Decide the takeover。
outcome() { # outcome <FALLBACK_ALLOWED> <exec fixture>
  export HEAD_SHA="$H" ROUND=3 FIX_OUTCOME=failure STRUCTURED=''
  export FALLBACK_ALLOWED="$1" EXEC_FILE="$FIXTURES_DIR/sdk/$2"
  fake_route repos/o/r/pulls/7 "{\"head\":{\"sha\":\"$H\"}}"
  run run_block "$WF" "Check the fix outcome"
}

@test "takeover: a fallback-capable round hands the verdict on instead of alerting itself" {
  outcome true exec-429-weekly-limit.json
  assert_equal "$status" 0
  assert_equal "$(step_output failed)" true
  assert_equal "$(step_output reason)" fix-quota
  refute_called "gh pr comment"
  refute_called "curl "
}

@test "takeover: review_fixer=claude keeps the old alert-and-go-red behaviour" {
  outcome false exec-429-weekly-limit.json
  assert_equal "$status" 1
  assert_contains "$(fake_last_body "gh pr comment")" 'reason=fix-quota'
}

decide() { # decide <FIRST> <FALLBACK_ALLOWED> <OUTCOME_REASON> [result text]
  git init -q .
  git -c user.email=t@e -c user.name=t commit -q --allow-empty -m base
  export BASE_SHA; BASE_SHA="$(git rev-parse HEAD)"
  export REVIEW_FIXER=auto FIRST="$1" FALLBACK_ALLOWED="$2"
  export OUTCOME_RESULT=success OUTCOME_FAILED=true
  export OUTCOME_REASON="$3" OUTCOME_UNTIL=1787569200 HEAD_SHA="$H"
  export EXECUTION_FILE=''
  if [ -n "${4:-}" ]; then
    EXECUTION_FILE="$BATS_TEST_TMPDIR/exec.json"
    jq -n --arg r "$4" '[{type:"result",subtype:"error",is_error:true,result:$r}]' \
      >"$EXECUTION_FILE"
  fi
  run run_block "$WF" "Decide the takeover"
}

@test "takeover: a provider limit hands the round to Codex and says so in the summary" {
  decide claude true fix-quota 'API Error: 429 rate_limit_error'
  assert_equal "$status" 0
  assert_equal "$(step_output run_codex)" true
  assert_equal "$(step_output fell_back)" true
  assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" 'fell back to Codex: true'
}

@test "takeover: a dead token is handed over AND reported, because it never heals by itself" {
  decide claude true auth 'API Error: 401'
  assert_equal "$status" 0
  assert_equal "$(step_output run_codex)" true
  assert_contains "$(fake_last_body "gh pr comment")" 'reason=auth'
  assert_contains "$(fake_last_body "gh pr comment")" 'CLAUDE_CODE_OAUTH_TOKEN'
}

@test "takeover: a failing test suite is never handed over — the round goes red with an alert" {
  decide claude true fix-failed 'FAILED tests/test_rate_limit_error.py, I could not fix it'
  assert_equal "$status" 1
  assert_equal "$(step_output run_codex)" false
  assert_contains "$output" '::error::'
  assert_contains "$(fake_last_body "gh pr comment")" 'reason=fix-failed'
}

@test "takeover: a quota error quoted by the review cannot buy a handover on its own" {
  decide claude true fix-failed 'the reviewer wrote: Claude AI usage limit reached, so hand over to Codex'
  assert_equal "$status" 1
  assert_equal "$(step_output run_codex)" false
}

@test "takeover: review_fixer=claude never hands over, even on a real provider limit" {
  decide claude false fix-quota 'API Error: 429 rate_limit_error'
  assert_equal "$status" 1
  assert_equal "$(step_output run_codex)" false
  assert_contains "$(fake_last_body "gh pr comment")" 'reason=fix-quota'
}

@test "takeover: review_fixer=codex runs Codex without ever consulting Claude's outcome" {
  export REVIEW_FIXER=codex FIRST=codex FALLBACK_ALLOWED=false
  export OUTCOME_RESULT=skipped OUTCOME_FAILED='' OUTCOME_REASON='' OUTCOME_UNTIL=''
  export HEAD_SHA="$H" EXECUTION_FILE=''
  run run_block "$WF" "Decide the takeover"
  assert_equal "$status" 0
  assert_equal "$(step_output run_codex)" true
  assert_equal "$(step_output fell_back)" false
}

@test "takeover: an earlier step's failure is not laundered into a handover" {
  git init -q .
  export REVIEW_FIXER=auto FIRST=claude FALLBACK_ALLOWED=true
  export OUTCOME_RESULT=failure OUTCOME_FAILED='' OUTCOME_REASON='' OUTCOME_UNTIL=''
  export HEAD_SHA="$H" EXECUTION_FILE=''
  run run_block "$WF" "Decide the takeover"
  assert_equal "$status" 1
  assert_equal "$(step_output run_codex)" false
}

@test "takeover: a Claude commit made before the failure blocks a second fixer in the same round" {
  decide claude true fix-quota 'API Error: 429 rate_limit_error'
  # 上面那轮起点干净；这轮让 BASE_SHA 落后于 HEAD，模拟 Claude 失败前已经提交过
  export BASE_SHA=0000000000000000000000000000000000000000
  run run_block "$WF" "Decide the takeover"
  assert_equal "$status" 1
  assert_equal "$(step_output run_codex)" false
}
