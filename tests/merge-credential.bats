#!/usr/bin/env bats
# 合并用主人的 PAT（CODEX_TRIGGER_TOKEN），合并出来的 commit 上才有 CI。
#
# 用 github.token 合并时，GitHub 的防递归规则让那次 push 不触发任何 workflow：调用方
# ci.yml 的 `on: push` 不跑，ff-main 的 CI 闸门见到「没有任何 CI 记录」就永远不挪 main
# （2026-10-07 wechat-mimic-finetune 12–15 号 PR 实测）。守四件事：
#   1. 有 PAT → 合并用它，而且只有那一条 gh pr merge 拿得到；
#   2. 没 PAT → 照旧用 github.token，行为跟以前一字不差；
#   3. PAT 合不动 → 退回 github.token 再合一次，不比以前差；
#   4. gh-workflows 自己的 SELF_WORKFLOWS_TOKEN 照旧优先。

# shellcheck disable=SC2030,SC2031

load test_helper/common

MERGE=.github/workflows/codex-approved-merge.yml
MERGE_STEP='Wait for Codex and merge a clean exact head'
CODEX='chatgpt-codex-connector[bot]'
H=1a7e81f6b5f27f0a1dbc33c6fafda1bb86f1483d

# 路径 A（PR 打开事件 + Codex 👍）+ CI 全绿，走到合并那一条。
setup() {
  setup_fake_env
  export REPO=o/r PR_NUMBER=7 BASE_BRANCH=develop GH_TOKEN=actions-token
  export GITHUB_RUN_ID=111 ACTOR_TYPE=User HAS_PAT=true
  export GITHUB_WORKFLOW='Merge after clean Codex review'
  export FAKE_NOW=2026-09-18T08:00:10Z TRIGGERED_AT=2026-09-18T08:00:00Z
  export EVENT_HEAD="$H" TARGET_ID=7 SELF_WORKFLOWS_TOKEN='' CODEX_TRIGGER_TOKEN=owner-pat
  unset WATCH_SECONDS POLL_SECONDS SILENT_SECONDS PUSHOVER_TOKEN PUSHOVER_USER
  fake_route repos/o/r/pulls/7 "$(
    jq -n --arg h "$H" '{
      state: "open", draft: false, title: "feat: x", merged: false,
      mergeable: true, mergeable_state: "clean",
      base: {ref: "develop"}, head: {sha: $h, repo: {full_name: "o/r"}}
    }'
  )"
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" '[]'
  fake_route "repos/o/r/issues/7/comments?per_page=100" '[]'
  fake_route "repos/o/r/issues/7/reactions?per_page=100" \
    "$(json_array "$(gh_reaction +1 "$CODEX" 2026-09-18T08:01:00Z)")"
  fake_cli pr_checks \
    '[{"name":"ci","state":"SUCCESS","bucket":"pass","link":"https://x","workflow":"CI"}]'
}

@test "merge: a repo with the owner PAT merges with it, and nothing else gets it" {
  run run_block "$MERGE" "$MERGE_STEP"

  assert_equal "$status" 0
  assert_contains "$output" 'the merge request uses the codex-trigger credential'
  # 等 Codex、读 PR、看 CI 的那些照旧用 github.token；PAT 只出现在合并那一条上。
  assert_called '[token=owner-pat]' 1
  assert_contains "$(fake_calls '[token=owner-pat]')" "gh pr merge 7 --repo o/r --squash --delete-branch --match-head-commit $H"
}

@test "merge: without the owner PAT it merges with github.token, as before" {
  export CODEX_TRIGGER_TOKEN=''

  run run_block "$MERGE" "$MERGE_STEP"

  assert_equal "$status" 0
  assert_contains "$output" 'the merge request uses the github-token credential'
  assert_called 'gh pr merge 7' 1
  assert_contains "$(fake_calls 'gh pr merge 7')" '[token=actions-token]'
  refute_contains "$output" '::warning::'
}

@test "merge: gh-workflows still prefers its dedicated token over the owner PAT" {
  export REPO=Melodymaifafa/gh-workflows SELF_WORKFLOWS_TOKEN=self-token
  fake_route repos/Melodymaifafa/gh-workflows/pulls/7 "$(
    jq -n --arg h "$H" '{
      state: "open", draft: false, title: "feat: x", merged: false,
      mergeable: true, mergeable_state: "clean",
      base: {ref: "develop"}, head: {sha: $h, repo: {full_name: "Melodymaifafa/gh-workflows"}}
    }'
  )"
  fake_route "repos/Melodymaifafa/gh-workflows/pulls/7/reviews?per_page=100" '[]'
  fake_route "repos/Melodymaifafa/gh-workflows/issues/7/comments?per_page=100" '[]'
  fake_route "repos/Melodymaifafa/gh-workflows/issues/7/reactions?per_page=100" \
    "$(json_array "$(gh_reaction +1 "$CODEX" 2026-09-18T08:01:00Z)")"

  run run_block "$MERGE" "$MERGE_STEP"

  assert_equal "$status" 0
  assert_contains "$output" 'the merge request uses the self-workflows credential'
  assert_contains "$(fake_calls 'gh pr merge 7')" '[token=self-token]'
  refute_called '[token=owner-pat]'
}

@test "merge: a PAT the merge refuses falls back to github.token and still merges" {
  fake_cli_fail pr_merge 1 'HTTP 401: Bad credentials (https://api.github.com/graphql)' 1
  fake_cli pr_merge 'merged' 2

  run run_block "$MERGE" "$MERGE_STEP"

  assert_equal "$status" 0
  assert_called 'gh pr merge 7' 2
  assert_contains "$(fake_calls 'gh pr merge 7' | head -1)" '[token=owner-pat]'
  assert_contains "$(fake_calls 'gh pr merge 7' | tail -1)" '[token=actions-token]'
  assert_contains "$output" '::warning::CODEX_TRIGGER_TOKEN could not merge; retrying with github.token'
  refute_called 'gh api POST'
}

@test "merge: when github.token is refused too, the existing merge-failed alert fires once" {
  fake_cli_fail pr_merge 1 'GraphQL: Something went wrong (mergePullRequest)'

  run run_block "$MERGE" "$MERGE_STEP"

  assert_equal "$status" 1
  assert_called 'gh pr merge 7' 2
  assert_called 'gh api POST repos/o/r/issues/7/comments' 1
  assert_called 'reason=merge-failed until=-' 1
}

# PAT 能改所有仓库的代码和流水线：job 层只许拿到「有没有」，值只给合并那一步。
@test "scope: the watch job sees only whether the PAT exists; the merge step holds the value" {
  job="$(awk '/^  watch-and-merge:/{on=1} /^  claude-review:/{on=0} on' "$REPO_ROOT/$MERGE")"
  assert_equal "$(grep -c 'secrets.CODEX_TRIGGER_TOKEN' <<<"$job")" 2
  assert_contains "$job" "HAS_PAT: \${{ secrets.CODEX_TRIGGER_TOKEN != '' }}"
  assert_contains "$(step_env_keys "$MERGE" "$MERGE_STEP")" 'CODEX_TRIGGER_TOKEN'
}
