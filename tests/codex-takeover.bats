#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats 每个 @test 是子 shell
# claude-codex-iterate.yml 的 Codex 接管路径：意见怎么交到 Codex 手上，以及
# 「Claude 这轮没跑成」之后谁来下结论。守三件事：
#   1. 拿不到 review 就红着停下 —— 空 review 会让 Codex 不改任何文件、job 打
#      绿勾收工，链条静默停住。
#   2. 交出去的是 Gate 预取的那份意见，不是调用方仓库里同名的文件 —— 交接前
#      的 git reset --hard 恢复被跟踪文件，.git/info/exclude 挡不住它。
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
  export RUN_SLUG=99-1
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
  assert_equal "$(step_output file)" .review/findings-99-1.md
  assert_contains "$(cat codex-review-context.md)" 'already tracks'
  assert_contains "$(cat .review/findings-99-1.md)" 'this swallows the error'
}

# 预取的正文躺在调用方的工作副本里，而交接前要 git reset --hard 回起点。
# .git/info/exclude 只挡 git add 和 git clean，挡不住 reset 恢复被跟踪文件：
# 调用方仓库自己跟踪了一个 .review/findings.md 时，reset 会拿他们那份盖掉预取
# 的那份，非空检查照样通过，Codex 对着一份跟本 PR 无关的内容改代码。
@test "takeover: the caller's own tracked .review/findings.md cannot displace the prefetch" {
  handover_workspace
  printf 'a file the caller repo tracks under .review\n' >.review/findings.md
  git add -f .review/findings.md
  git commit -q -m 'the caller tracks .review/findings.md too'
  export BASE_SHA; BASE_SHA="$(git rev-parse HEAD)"
  # Gate 把本轮的意见预取进去，盖在被跟踪的那份上面
  printf '## 行内评论\n\n- scripts/x.sh:12 — this swallows the error\n' >.review/findings.md

  run run_block "$WF" "Hand the round over to Codex"

  assert_equal "$status" 0
  handed="$(step_output file)"
  assert_contains "$(cat "$handed")" 'this swallows the error'
  refute_contains "$(cat "$handed")" 'the caller repo tracks'
  # 交出去的那份还必须是 git 看不见的，否则下一步 git add -A 会把它提交进 PR
  assert_equal "$(git status --porcelain)" ''
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
  [ -s .review/findings-99-1.md ]
}

# ---------- 验证、提交、推送 ----------

# Verify, commit and push 那一步的工作区：一个带 origin 的真仓库，加上 Codex 刚
# 改过的文件。VERIFY 是被审 PR 自己带的命令，这里换成探针，用来看它看得见什么。
push_workspace() { # push_workspace <verify script>
  git init -q -b topic .
  git config user.email t@e
  git config user.name t
  printf 'v1\n' >app.txt
  printf 'lock v1\n' >deps.lock
  git add app.txt deps.lock
  git commit -q -m base
  git init -q --bare "$BATS_TEST_TMPDIR/origin.git"
  git remote add origin "$BATS_TEST_TMPDIR/origin.git"
  git push -q origin HEAD:topic
  # actions/checkout 把写权限凭据持久化成这一条 config
  git config --local http.https://github.com/.extraheader 'AUTHORIZATION: basic c2VjcmV0'
  mkdir -p .git/info .review
  echo '.review/' >>.git/info/exclude
  printf 'prefetched review\n' >.review/findings-99-1.md
  printf 'v2 fixed by codex\n' >app.txt
  export VERIFY="$1"
  export HEAD_REF=topic PR_NUMBER=7 ROUND=2 REPO=o/r GH_TOKEN=write-token
}

# 验证命令来自被审的那个 PR：npm ci 的生命周期钩子、pytest 插件、bats 里的任意
# 一行都能执行代码。它跑的时候环境里不能有 contents:write 的令牌，也不能有
# checkout 留在 .git/config 里的凭据 —— 拿到任何一样就等于拿到仓库写权限。
@test "takeover: the PR's own verify command runs without any write credential" {
  push_workspace 'printf "GH_TOKEN=[%s]\n" "${GH_TOKEN:-}" >"$BATS_TEST_TMPDIR/probe.txt"
git config --local --get http.https://github.com/.extraheader >>"$BATS_TEST_TMPDIR/probe.txt" ||
  echo "git-credential=[]" >>"$BATS_TEST_TMPDIR/probe.txt"'

  run run_block "$WF" "Verify, commit and push the Codex fix"

  assert_equal "$status" 0
  assert_contains "$(cat "$BATS_TEST_TMPDIR/probe.txt")" 'GH_TOKEN=[]'
  assert_contains "$(cat "$BATS_TEST_TMPDIR/probe.txt")" 'git-credential=[]'
  # push 和发评论还要用，验证跑完必须原样还回来
  assert_equal "$(git config --local --get http.https://github.com/.extraheader)" 'AUTHORIZATION: basic c2VjcmV0'
  assert_equal "$(step_output pushed)" true
}

# 提交的必须是验过的那棵树：验证自己会改被跟踪的文件（uv sync --dev 重写
# uv.lock），同时造出不该提交的垃圾目录。两个性质得同时成立。
@test "takeover: the commit carries the tree the verification actually ran on" {
  push_workspace 'printf "lock v2\n" >deps.lock
mkdir -p .venv && printf "junk\n" >.venv/pyvenv.cfg
printf "cached\n" >stray.pyc'

  run run_block "$WF" "Verify, commit and push the Codex fix"

  assert_equal "$status" 0
  assert_equal "$(git show HEAD:deps.lock)" 'lock v2'
  assert_equal "$(git show HEAD:app.txt)" 'v2 fixed by codex'
  tree="$(git ls-tree -r --name-only HEAD)"
  refute_contains "$tree" '.venv'
  refute_contains "$tree" 'stray.pyc'
  refute_contains "$tree" '.review'
  # 推出去的和本地提交的是同一棵
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse origin/topic)"
}

@test "takeover: a failing verification pushes nothing" {
  push_workspace 'exit 3'

  run run_block "$WF" "Verify, commit and push the Codex fix"

  assert_equal "$status" 1
  assert_contains "$output" 'verification failed'
  refute_called "gh pr comment"
  # 凭据照样还回来，不能因为验证失败就永久摘掉
  assert_equal "$(git config --local --get http.https://github.com/.extraheader)" 'AUTHORIZATION: basic c2VjcmV0'
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

decide() { # decide <FIRST> <FALLBACK_ALLOWED> <OUTCOME_REASON> [result text] [api_error_status]
  git init -q .
  git -c user.email=t@e -c user.name=t commit -q --allow-empty -m base
  export BASE_SHA; BASE_SHA="$(git rev-parse HEAD)"
  export REVIEW_FIXER=auto FIRST="$1" FALLBACK_ALLOWED="$2"
  export OUTCOME_RESULT=success OUTCOME_FAILED=true
  export OUTCOME_REASON="$3" OUTCOME_UNTIL=1787569200 HEAD_SHA="$H"
  export EXECUTION_FILE=''
  if [ -n "${4:-}" ]; then
    EXECUTION_FILE="$BATS_TEST_TMPDIR/exec.json"
    jq -n --arg r "$4" --arg s "${5:-}" \
      '[{type:"result",subtype:"error",is_error:true,result:$r}
        + (if $s == "" then {} else {api_error_status: ($s | tonumber)} end)]' \
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

# 模型写的 `.result` 跨多行是常态（markdown 小结、分条列举），而调用方只给它的
# 第一行拼上 `<subtype> <is_error> ` 前缀，第 2 行起是裸行。下面两条走的是这一格
# 真正的 jq，不是手搓字符串。
@test "takeover: a quota marker on a later line of the summary buys nothing" {
  decide claude true fix-failed "$(printf '%s\n' \
    'I could not fix the failing test.' \
    'API Error: 429 is what the mock is supposed to raise, and the assertion still fails.' \
    'Giving up after 3 attempts.')"
  assert_equal "$status" 1
  assert_equal "$(step_output run_codex)" false
  assert_contains "$output" '::error::'
  assert_contains "$(fake_last_body "gh pr comment")" 'reason=fix-failed'
}

@test "takeover: an error code on a later line of the summary buys nothing" {
  decide claude true fix-failed "$(printf '%s\n' \
    'Could not get the suite green.' \
    'overloaded_error is the case the new test covers; my handler still returns 500.')"
  assert_equal "$status" 1
  assert_equal "$(step_output run_codex)" false
}

# 503 / 529 上一步归到 fix-failed，能证明是 provider 侧失败的只有 execution_file
# 里 SDK 写的 api_error_status —— 下面两条守的是「证据必须来自那个字段」。
@test "takeover: a provider status only the SDK field knows still hands the round over" {
  decide claude true fix-failed 'API Error: 529 Overloaded' 529
  assert_equal "$status" 0
  assert_equal "$(step_output run_codex)" true
  assert_equal "$(step_output fell_back)" true
}

@test "takeover: the same 529 wording without the SDK field is not evidence" {
  decide claude true fix-failed 'API Error: 529 Overloaded'
  assert_equal "$status" 1
  assert_equal "$(step_output run_codex)" false
}

# 状态码只能从终态那一条 result 上读。把所有 result 的状态码收成数组再取 last，
# 会捡起中途那条 429 —— 而终态其实是「代码没修好、根本没有状态码」。分类器只信
# 这段结构化裸行，于是一次本该打红的业务失败直接买到一次换人，接手的那个 token
# 有写权限。
@test "takeover: a 429 on an earlier record buys nothing when the terminal record is a business failure" {
  git init -q .
  git -c user.email=t@e -c user.name=t commit -q --allow-empty -m base
  export BASE_SHA; BASE_SHA="$(git rev-parse HEAD)"
  export REVIEW_FIXER=auto FIRST=claude FALLBACK_ALLOWED=true
  export OUTCOME_RESULT=success OUTCOME_FAILED=true
  export OUTCOME_REASON=fix-failed OUTCOME_UNTIL=- HEAD_SHA="$H"
  export EXECUTION_FILE="$BATS_TEST_TMPDIR/exec.json"
  jq -n '[
      {type:"result",subtype:"error",is_error:true,api_error_status:429,result:"transient blip, retrying"},
      {type:"assistant"},
      {type:"result",subtype:"error",is_error:true,result:"the assertion still fails after 3 attempts"}
    ]' >"$EXECUTION_FILE"

  run run_block "$WF" "Decide the takeover"

  assert_equal "$status" 1
  assert_equal "$(step_output run_codex)" false
  assert_contains "$(fake_last_body "gh pr comment")" 'reason=fix-failed'
}

@test "takeover: a provider status on the terminal record still hands the round over" {
  git init -q .
  git -c user.email=t@e -c user.name=t commit -q --allow-empty -m base
  export BASE_SHA; BASE_SHA="$(git rev-parse HEAD)"
  export REVIEW_FIXER=auto FIRST=claude FALLBACK_ALLOWED=true
  export OUTCOME_RESULT=success OUTCOME_FAILED=true
  export OUTCOME_REASON=fix-failed OUTCOME_UNTIL=- HEAD_SHA="$H"
  export EXECUTION_FILE="$BATS_TEST_TMPDIR/exec.json"
  jq -n '[
      {type:"result",subtype:"error",is_error:true,result:"first attempt failed"},
      {type:"result",subtype:"error",is_error:true,api_error_status:529,result:"gave up"}
    ]' >"$EXECUTION_FILE"

  run run_block "$WF" "Decide the takeover"

  assert_equal "$status" 0
  assert_equal "$(step_output run_codex)" true
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

# 发总结那一步偶发挂一次（gh pr comment 限流、网络抖动），不能把召唤复审一起
# 带走：召唤发不出去 = Codex 刚推的那笔提交没人复看，链条静默停在这里。所以
# 召唤排在发总结之前。
@test "gating: a flaky summary comment cannot stop the re-review summon" {
  codex_mode_context
  gate_fails 'Post the Codex summary comment'
  gate_trace "$WF"

  gate_ran 'Verify, commit and push the Codex fix'
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
