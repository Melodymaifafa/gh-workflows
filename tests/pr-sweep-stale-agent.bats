#!/usr/bin/env bats
# 巡检接手没人管的 agent/* PR：最近更新在 24 小时内的不碰，严格超过 24 小时才当普通 PR 处理。别的分支不看这个时间。

load test_helper/common

H=1a7e81f6b5f27f0a1dbc33c6fafda1bb86f1483d
R=Melodymaifafa/private-caller
KICK_BODY="@codex review

<!-- codex-review-head: $H -->
<!-- pr-sweeper: kick -->"

setup() {
  setup_fake_env
  export OWNER=Melodymaifafa SWEEP_MODE=live ONLY_REPOS=private-caller GH_TOKEN=owner-pat SWEEP_LOG_REAL_NAMES=1
  NOW_EPOCH="$(jq -n '"2026-09-18T12:00:00Z" | fromdateiso8601')"
  export NOW_EPOCH
  unset PUSHOVER_TOKEN PUSHOVER_USER
  fake_route "user/repos?affiliation=owner&per_page=100" sweep/user-repos.json
  fake_route "repos/$R/contents/.github/workflows/codex-approved-merge.yml" \
    "$(printf '%s\n' 'jobs:' '  merge:' '    uses: Melodymaifafa/gh-workflows/.github/workflows/codex-approved-merge.yml@v1')"
  fake_route "repos/Melodymaifafa/gh-workflows/issues?state=open&creator=Melodymaifafa&per_page=100" '[]'
}

# open_prs <号>:<分支>:<updated 几秒前> …：除了这三样，字段全一样（没人碰过、够空闲，规则 5 碰上谁都 kick），
# 所以碰不碰只能取决于分支和更新时间。
open_prs() {
  local spec n ref ago pr list=()
  for spec in "$@"; do
    IFS=: read -r n ref ago <<<"$spec"
    pr="$(jq -n --argjson n "$n" --arg ref "$ref" --arg h "$H" --arg r "$R" \
      --arg u "$(jq -nr --argjson t "$((NOW_EPOCH - ago))" '$t | todate')" '{
      number: $n, state: "open", draft: false, title: "feat: something", merged: false, mergeable_state: "clean",
      updated_at: $u, html_url: "https://github.com/\($r)/pull/\($n)",
      head: {ref: $ref, sha: $h, repo: {full_name: $r}}, base: {ref: "develop", repo: {full_name: $r}}}')"
    list+=("$pr")
    fake_route "repos/$R/pulls/$n" "$pr"
    fake_route "repos/$R/issues/$n/comments?per_page=100" '[]'
    fake_route "repos/$R/pulls/$n/reviews?per_page=100" '[]'
  done
  fake_route "repos/$R/pulls?state=open&per_page=100" "$(json_array "${list[@]}")"
}

sweep() { run bash "$REPO_ROOT/scripts/pr-sweep.sh"; }

assert_kicked() {
  assert_contains "$output" "$R#$1 (${H:0:7}): idle="
  assert_called "gh api POST repos/$R/issues/$1/comments" 1
  assert_equal "$(fake_last_body "gh api POST repos/$R/issues/$1/comments")" "$KICK_BODY"
}

# 不光没写：连这个 PR 的详情、评论都没读过。
refute_touched() {
  refute_contains "$output" "$R#$1"
  refute_called "repos/$R/pulls/$1"
  refute_called "repos/$R/issues/$1/"
}

@test "an agent/* PR updated 23 hours ago is left alone; one updated 25 hours ago is handled like any other PR" {
  open_prs "7:agent/mel-7:$((23 * 3600))" "8:agent/mel-8:$((25 * 3600))"
  sweep
  assert_equal "$status" 0
  refute_touched 7
  assert_kicked 8
}

@test "the takeover is strict: exactly 24 hours is still left alone, one second more is not" {
  open_prs "7:agent/mel-7:86400" "8:agent/mel-8:86401"
  sweep
  assert_equal "$status" 0
  refute_touched 7
  assert_kicked 8
}

@test "other branches do not wait on the quiet time, including one that only looks like agent/*" {
  open_prs "7:topic:$((23 * 3600))" "8:topic-2:$((25 * 3600))" "9:agents/mel-9:$((23 * 3600))"
  sweep
  assert_equal "$status" 0
  assert_kicked 7
  assert_kicked 8
  assert_kicked 9
}
