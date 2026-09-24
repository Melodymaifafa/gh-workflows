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
load test_helper/step_gate

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

# Gate 之后的工作区：调用方仓库已经 checkout 好，意见预取在 .review/ 里，
# 而 .review/ 已写进本地 exclude（Gate 那步干的，iterate-gate.bats 盯着）。
handover_workspace() {
  git init -q .
  git config user.email t@e
  git config user.name t
  printf 'a file the caller repo already tracks\n' >codex-review-context.md
  git add codex-review-context.md
  git commit -q -m base
  export BASE_SHA; BASE_SHA="$(git rev-parse HEAD)"
  mkdir -p .git/info .review
  echo '.review/' >>.git/info/exclude
  printf '## 行内评论\n\n- scripts/x.sh:12 — this swallows the error\n' >.review/findings.md
}

@test "takeover: Codex is never handed a missing or empty review" {
  handover_workspace
  mv .review/findings.md .review/gone.md
  run run_block "$WF" "Hand the round over to Codex"
  assert_equal "$status" 1
  assert_contains "$output" '::error::'
  assert_contains "$output" 'incomplete review'

  mv .review/gone.md .review/findings.md
  : >.review/findings.md
  run run_block "$WF" "Hand the round over to Codex"
  assert_equal "$status" 1
}

@test "takeover: the handoff names the excluded prefetch, not a file in the caller's checkout" {
  handover_workspace

  run run_block "$WF" "Hand the round over to Codex"

  assert_equal "$status" 0
  assert_equal "$(step_output file)" .review/findings.md
  assert_contains "$(cat codex-review-context.md)" 'already tracks'
  assert_contains "$(cat .review/findings.md)" 'this swallows the error'
}

@test "takeover: Claude's uncommitted leftovers never ship as a Codex fix" {
  handover_workspace
  # Claude 改了工作区又没提交就撞了额度
  printf 'half-finished edit\n' >>codex-review-context.md
  printf 'a stray new file\n' >claude-wip.txt

  run run_block "$WF" "Hand the round over to Codex"

  assert_equal "$status" 0
  assert_contains "$(cat codex-review-context.md)" 'already tracks'
  refute_contains "$(cat codex-review-context.md)" 'half-finished'
  [ ! -e claude-wip.txt ]
  [ -s .review/findings.md ]
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

# 正常路径上 Check the fix outcome 会先打红，走不到这一步；这里守的是兜底本身。
@test "takeover: review_fixer=claude never hands over, even on a real provider limit" {
  decide claude false fix-quota 'API Error: 429 rate_limit_error'
  assert_equal "$status" 1
  assert_equal "$(step_output run_codex)" false
  assert_contains "$output" 'forbids a fallback'
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

# ---------------------------------------------------------------------------
# step 门禁（MEL-250 F1）
#
# 上面那条 "review_fixer=codex runs Codex without ever consulting Claude's
# outcome" 抽的是 Decide the takeover 一格 shell，断言 run_codex=true —— 它绿
# 着，可 Codex 接管那四步一次都没跑过。差的不在那一格里，在 GitHub 的门禁：
# step 的 if 不写状态函数时会被隐式补上 success()，前面一红，后面全跳。
# 下面这组按门禁语义重放整条 step 链（if 表达式从 workflow 原文读），补上那条
# 单块测试看不见的链路。
# ---------------------------------------------------------------------------

# codex 模式下 workflow 各处 if 引用到的值。
codex_mode_context() {
  gate_reset
  gate_set inputs.runtime shell
  gate_set inputs.review_fixer codex
  gate_set steps.gate.outputs.run true
  gate_set steps.select.outputs.first codex
  gate_set steps.select.outputs.fallback_allowed false
  # Decide the takeover 在 FIRST=codex 时输出 run_codex=true，由上面那条单块
  # 测试保证；跳过时这些 outputs 会被自动作废，不会假装还在。
  gate_set steps.decide.outputs.run_codex true
  gate_set steps.codex_push.outputs.pushed true
  # 上一条测试实测过：这一步真跑起来必然 exit 1（读到空结果 → 冤枉 Claude →
  # 打红）。所以只要它没被挡住，隐式 success() 就塌了。
  gate_fails 'Check the fix outcome'
}

@test "gating: the outcome step would fail and blame a Claude that never ran" {
  # 这条不判 if，只判「万一它真跑起来会怎样」—— 下面两条的前提。
  export HEAD_SHA="$H" ROUND=3 FIX_OUTCOME=skipped STRUCTURED='' EXEC_FILE=''
  export FALLBACK_ALLOWED=false
  fake_route repos/o/r/pulls/7 "{\"head\":{\"sha\":\"$H\"}}"

  run run_block "$WF" "Check the fix outcome"

  [ "$status" -ne 0 ]
  assert_contains "$(fake_last_body "gh pr comment")" 'Claude 自动修复没跑成'
}

@test "gating: review_fixer=codex actually reaches all four Codex steps" {
  codex_mode_context
  gate_trace "$WF"

  gate_skipped 'uses: anthropics/claude-code-action@v1'
  gate_skipped 'Check the fix outcome'
  gate_ran 'Decide the takeover'
  gate_ran 'Hand the round over to Codex'
  gate_ran 'Codex fixes the PR'
  gate_ran 'Verify, commit and push the Codex fix'
  gate_ran 'Post the Codex summary comment'
  gate_ran 'Request Codex re-review after a new commit'
}

@test "gating: without the first=='claude' half, the whole takeover is skipped" {
  # 把 Check the fix outcome 的 if 换回只看 gate 的旧写法，并按上面那条测出来的
  # 结果让它失败 —— 隐式 success() 随即为假，Codex 四步全被跳过。模型抓不到这个
  # 回归，上面那条「四步都跑到」就是假绿。
  codex_mode_context
  gate_if 'Check the fix outcome' "steps.gate.outputs.run == 'true'"
  gate_fails 'Check the fix outcome'
  gate_trace "$WF"

  gate_ran 'Check the fix outcome'
  gate_ran 'Decide the takeover'
  gate_skipped 'Hand the round over to Codex'
  gate_skipped 'Codex fixes the PR'
  gate_skipped 'Verify, commit and push the Codex fix'
  gate_skipped 'Post the Codex summary comment'
  gate_skipped 'Request Codex re-review after a new commit'
}

@test "gating: auto and claude modes still run Claude and judge its outcome" {
  # 新加的那半个条件只能挡住 codex 模式；挡到 Claude 自己那两条路上，
  # 失败就再也没人分类、没人告警了。
  for mode in auto claude; do
    gate_reset
    gate_set inputs.runtime shell
    gate_set inputs.review_fixer "$mode"
    gate_set steps.gate.outputs.run true
    gate_set steps.select.outputs.first claude
    # Claude 那一步带 continue-on-error，撞额度也不许把后面的判定一起拖红
    gate_fails 'uses: anthropics/claude-code-action@v1'
    gate_trace "$WF"

    gate_ran 'uses: anthropics/claude-code-action@v1'
    gate_ran 'Check the fix outcome'
    gate_ran 'Decide the takeover'
  done
}

@test "gating: a round the gate turned off runs neither fixer" {
  gate_reset
  gate_set inputs.runtime shell
  gate_set inputs.review_fixer auto
  gate_set steps.gate.outputs.run false
  gate_trace "$WF"

  gate_skipped 'Select the review fixer'
  gate_skipped 'uses: anthropics/claude-code-action@v1'
  gate_skipped 'Check the fix outcome'
  gate_skipped 'Decide the takeover'
  gate_skipped 'Codex fixes the PR'
}
