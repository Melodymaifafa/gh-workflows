#!/usr/bin/env bats
# 本仓库专用的写权限令牌 SELF_WORKFLOWS_TOKEN（MEL-295）。
#
# GitHub 不许没有 Workflows 权限的令牌推、合 `.github/workflows/` 下的改动，而
# gh-workflows 自己的 PR 几乎都改这些文件 —— 2026-09-26 到 10-01，本仓库 17 / 18 / 19
# 号 PR 为此停了 4 次。所以这一个仓库多设一个密钥，值复用加了 Workflows 写权限的
# CODEX_TRIGGER_TOKEN（2026-10-06）。守四件事：
#   1. 本仓库 + 密钥非空 → 推送和合并用它；
#   2. 别的仓库 → 不用它，哪怕那边也设了一个同名密钥；
#   3. 没设密钥 → 照旧用 `github.token`，行为跟没有这个功能时一字不差，run 不变红；
#   4. 它只出现在「推送」和「合并」那三步的 `env:` 里 —— 跑验证命令的步骤、跑被审 PR
#      代码的步骤、Claude / Codex 那几步一律看不到，也不许进 onboard.sh / secrets.env
#      （那两处会把密钥刷到所有仓库去）。

# bats 每个 @test 本来就跑在子 shell 里，export 只给本测试用。
# shellcheck disable=SC2030,SC2031

load test_helper/common

ITERATE=.github/workflows/claude-codex-iterate.yml
MERGE=.github/workflows/codex-approved-merge.yml
MERGE_STEP='Wait for Codex and merge a clean exact head'
SELF_REPO=Melodymaifafa/gh-workflows
CODEX='chatgpt-codex-connector[bot]'
H=1a7e81f6b5f27f0a1dbc33c6fafda1bb86f1483d

setup() {
  setup_fake_env
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp"
  mkdir -p "$RUNNER_TEMP" "$BATS_TEST_TMPDIR/work"
  cd "$BATS_TEST_TMPDIR/work" || return
  # 推送正文走 step output 交出去，真跑时由 env: 接过去（MEL-262）；这里照同一条路取。
  run_block "$ITERATE" 'Define the fix push guard' >/dev/null
  export FIX_PUSH_GUARD; FIX_PUSH_GUARD="$(step_output push)"
  : >"$GITHUB_OUTPUT"
}

# ---------- 判定本身：跑的是 workflow 交出来的那一份，不是测试里另写一份 ----------

# push_source <repo> <secret>
push_source() {
  (
    eval "$FIX_PUSH_GUARD"
    REPO="$1" SELF_WORKFLOWS_TOKEN="$2" push_credential_source
  )
}

@test "token: gh-workflows with the secret set picks the dedicated token" {
  assert_equal "$(push_source "$SELF_REPO" self-token)" self-workflows
}

@test "token: another repo picks github.token even with a secret by that name" {
  assert_equal "$(push_source o/r self-token)" github-token
}

@test "token: gh-workflows without the secret picks github.token" {
  assert_equal "$(push_source "$SELF_REPO" '')" github-token
}

@test "token: another repo without the secret picks github.token" {
  assert_equal "$(push_source o/r '')" github-token
}

# ---------- 推送：真跑一遍那一步 ----------

# 推送那一步要的最小工作区：一个带 origin 的真仓库，改动已经入索引 —— 真跑时那次
# `add -u` 在验证那一步做，这里直接摆成它跑完的样子。
push_workspace() {
  git init -q -b topic .
  git config user.email t@e
  git config user.name t
  printf 'v1\n' >app.txt
  git add app.txt
  git commit -q -m base
  git init -q --bare "$BATS_TEST_TMPDIR/origin.git"
  git remote add origin "$BATS_TEST_TMPDIR/origin.git"
  git push -q origin HEAD:topic
  printf 'v2 fixed\n' >app.txt
  git add -u
  export HEAD_REF=topic PR_NUMBER=7 ROUND=2 GH_TOKEN=actions-token
  # 轮数标记 M7 走 gh，而 gh 只从写不动的目录里找 —— 假 gh 在仓库目录下，不接回来够不着。
  trust_fake_bin
}

@test "push: gh-workflows pushes the fix with the dedicated token" {
  push_workspace
  export REPO="$SELF_REPO" SELF_WORKFLOWS_TOKEN=self-token

  run run_step "$ITERATE" 'Commit and push the Claude fix'

  assert_equal "$status" 0
  assert_contains "$output" 'the fix push uses the self-workflows credential'
  assert_equal "$(step_output pushed)" true
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse origin/topic)"
  # 专用令牌只给那一条 git push：同一步里的 gh pr comment 照旧用 github.token，
  # M7 标记于是仍由 github-actions[bot] 署名（可信作者的判定不跟着变）。
  assert_contains "$(fake_calls 'gh pr comment')" '[token=actions-token]'
  refute_called '[token=self-token]'
}

@test "push: the Codex path uses the same dedicated token" {
  push_workspace
  export REPO="$SELF_REPO" SELF_WORKFLOWS_TOKEN=self-token

  run run_step "$ITERATE" 'Commit and push the Codex fix'

  assert_equal "$status" 0
  assert_contains "$output" 'the fix push uses the self-workflows credential'
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse origin/topic)"
  refute_called '[token=self-token]'
}

@test "push: another repo pushes with github.token" {
  push_workspace
  export REPO=o/r SELF_WORKFLOWS_TOKEN=self-token

  run run_step "$ITERATE" 'Commit and push the Claude fix'

  assert_equal "$status" 0
  assert_contains "$output" 'the fix push uses the github-token credential'
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse origin/topic)"
}

@test "push: gh-workflows without the secret pushes with github.token and stays green" {
  push_workspace
  export REPO="$SELF_REPO" SELF_WORKFLOWS_TOKEN=''

  run run_step "$ITERATE" 'Commit and push the Claude fix'

  assert_equal "$status" 0
  assert_contains "$output" 'the fix push uses the github-token credential'
  assert_equal "$(step_output pushed)" true
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse origin/topic)"
}

# ---------- 合并：真跑一遍那一步 ----------

# merge_setup <repo>：路径 A（PR 打开事件 + Codex 👍）+ CI 全绿，走到合并那一条。
merge_setup() {
  export REPO="$1" PR_NUMBER=7 BASE_BRANCH=develop GH_TOKEN=actions-token
  export GITHUB_RUN_ID=111 ACTOR_TYPE=User HAS_PAT=true
  export GITHUB_WORKFLOW='Merge after clean Codex review'
  export FAKE_NOW=2026-09-18T08:00:10Z TRIGGERED_AT=2026-09-18T08:00:00Z
  export EVENT_HEAD="$H" TARGET_ID=7
  unset WATCH_SECONDS POLL_SECONDS SILENT_SECONDS PUSHOVER_TOKEN PUSHOVER_USER
  fake_route "repos/$1/pulls/7" "$(
    jq -n --arg h "$H" --arg r "$1" '{
      state: "open", draft: false, title: "feat: x", merged: false,
      mergeable: true, mergeable_state: "clean",
      base: {ref: "develop"}, head: {sha: $h, ref: "topic", repo: {full_name: $r}}
    }'
  )"
  fake_route "repos/$1/pulls/7/reviews?per_page=100" '[]'
  fake_route "repos/$1/issues/7/comments?per_page=100" '[]'
  no_running_fix "$1"
  fake_route "repos/$1/issues/7/reactions?per_page=100" \
    "$(json_array "$(gh_reaction +1 "$CODEX" 2026-09-18T08:01:00Z)")"
  fake_cli pr_checks \
    '[{"name":"ci","state":"SUCCESS","bucket":"pass","link":"https://x","workflow":"CI"}]'
}

@test "merge: gh-workflows merges with the dedicated token and nothing else gets it" {
  merge_setup "$SELF_REPO"
  export SELF_WORKFLOWS_TOKEN=self-token

  run run_block "$MERGE" "$MERGE_STEP"

  assert_equal "$status" 0
  assert_contains "$output" 'the merge request uses the self-workflows credential'
  # 全部调用里只有一条带专用令牌，就是那条合并请求：等 Codex、读 PR、看 CI、发告警
  # 评论的那些照旧用 github.token。
  assert_called '[token=self-token]' 1
  assert_contains "$(fake_calls '[token=self-token]')" 'gh pr merge 7'
}

@test "merge: another repo merges with github.token even with a secret by that name" {
  merge_setup o/r
  export SELF_WORKFLOWS_TOKEN=self-token

  run run_block "$MERGE" "$MERGE_STEP"

  assert_equal "$status" 0
  assert_contains "$output" 'the merge request uses the github-token credential'
  assert_contains "$(fake_calls 'gh pr merge 7')" '[token=actions-token]'
  refute_called '[token=self-token]'
}

@test "merge: gh-workflows without the secret merges with github.token, as today" {
  merge_setup "$SELF_REPO"
  export SELF_WORKFLOWS_TOKEN=''

  run run_block "$MERGE" "$MERGE_STEP"

  assert_equal "$status" 0
  assert_contains "$output" 'the merge request uses the github-token credential'
  assert_contains "$(fake_calls 'gh pr merge 7')" '[token=actions-token]'
}

# ---------- 只许这三步拿得到 ----------

# declaring_steps <workflow>：`env:` 里声明了这个密钥的步骤名，一行一个。
declaring_steps() {
  awk '
    /^      - name: / { step = substr($0, 15) }
    /^ +SELF_WORKFLOWS_TOKEN:/ { print step }
  ' "$REPO_ROOT/$1"
}

# 这把令牌能改所有仓库共用的流水线，所以只交给「推送」和「合并」。任何人把它加到第
# 五步，这一条就红 —— 而新加的那一步很可能正是跑被审 PR 代码的那种（MEL-254）。
# 解冲突那一步推的是合并提交，合进来的集成分支常带着 workflow 改动，所以也要它；那个 job
# 不运行 PR 里的任何代码（tests/resolve-conflict.bats 守着）。
@test "scope: exactly four steps declare the token — the two fix pushes, the merge and the conflict merge push" {
  assert_equal "$(declaring_steps "$ITERATE")" 'Commit and push the Claude fix
Commit and push the Codex fix'
  assert_equal "$(declaring_steps "$MERGE")" "$MERGE_STEP
Push the merge or hand it to a person"
}

@test "scope: the steps that run the PR's own verify command never see it" {
  for step in 'Verify the Claude fix' 'Verify the Codex fix'; do
    refute_contains "$(step_env_keys "$ITERATE" "$step")" 'SELF_WORKFLOWS_TOKEN'
  done
  # 验证那一份共用正文里一个字都没有它（两条路跑的是同一段，MEL-262）。
  refute_contains "$(fix_guard_body verify_the_fix)" 'SELF_WORKFLOWS_TOKEN'
}

@test "scope: no other workflow or caller stub mentions it" {
  for wf in "$REPO_ROOT"/.github/workflows/*.yml "$REPO_ROOT"/stubs/*.yml; do
    case "${wf##*/}" in claude-codex-iterate.yml | codex-approved-merge.yml | move-v1.yml) continue ;; esac
    refute_contains "$(cat "$wf")" 'SELF_WORKFLOWS_TOKEN'
  done
}

# 每天移 v1 那一步也要它：普通令牌改不了指向含 workflow 改动的提交的标签。它能拿，是因为
# 那个 workflow 只由定时和手动触发，手动选了别的分支第一步就停（move-v1.bats 守着）—— 没有任何
# PR 的代码会在那里跑。
# 谁给它加上 pull_request / issue_comment 之类的触发，这条就红。
@test "scope: the daily v1 move only ever runs on a schedule or by hand" {
  triggers="$(awk '/^on:/ { f = 1; next } f && /^[a-z]/ { exit } f && /^  [a-z_]+:/ { sub(/:.*/, ""); sub(/^  /, ""); print }' \
    "$REPO_ROOT/.github/workflows/move-v1.yml" | sort | tr '\n' ' ')"
  assert_equal "$triggers" 'schedule workflow_dispatch '
}

# 进了这三个文件，密钥就会被刷到所有接了流水线的仓库 —— 而它能改大家共用的流水线。
@test "scope: it stays out of onboard.sh, newrepo.sh and the secrets.env template" {
  for f in onboard.sh newrepo.sh secrets.env.example; do
    refute_contains "$(cat "$REPO_ROOT/$f")" 'SELF_WORKFLOWS_TOKEN'
  done
}
