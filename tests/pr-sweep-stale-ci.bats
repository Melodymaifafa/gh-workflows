#!/usr/bin/env bats
# CI 红停车后严格超过 24 小时没动静的 PR：巡检告警一次 ci-stale 叫人（推手机 + PR 上一句话），不看分支名；
# 叫过之后这个 head 每轮不再记日志。没满 24 小时照旧只记「CI 红，已停车」。

load test_helper/common

H=1a7e81f6b5f27f0a1dbc33c6fafda1bb86f1483d
OTHER=9b14fe3aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
R=Melodymaifafa/private-caller
STALE_MARKER="<!-- pr-guard: alert head=$H reason=ci-stale until=- -->"

setup() {
  setup_fake_env
  export OWNER=Melodymaifafa SWEEP_MODE=live ONLY_REPOS=private-caller GH_TOKEN=owner-pat SWEEP_LOG_REAL_NAMES=1
  NOW_EPOCH="$(jq -n '"2026-09-18T12:00:00Z" | fromdateiso8601')"
  export NOW_EPOCH PUSHOVER_TOKEN=t PUSHOVER_USER=u
  fake_route "user/repos?affiliation=owner&per_page=100" sweep/user-repos.json
  fake_route "repos/$R/contents/.github/workflows/codex-approved-merge.yml" \
    "$(printf '%s\n' 'jobs:' '  merge:' '    uses: Melodymaifafa/gh-workflows/.github/workflows/codex-approved-merge.yml@v1')"
  fake_route "repos/Melodymaifafa/gh-workflows/issues?state=open&creator=Melodymaifafa&per_page=100" '[]'
  fake_route "repos/$R/pulls/7/reviews?per_page=100" '[]'
}

# red_pr <分支> <几秒前停的车> [其他评论…]：PR #7 CI 红（unstable），合并工作流那时在 H 上留了 ci 告警，之后没人动。
# PR_STATE 换掉 mergeable_state（CI 又绿了就是 clean）。
red_pr() {
  local at pr
  at="$(jq -nr --argjson t "$((NOW_EPOCH - $2))" '$t | todate')"
  pr="$(jq -n --arg ref "$1" --arg h "$H" --arg r "$R" --arg u "$at" --arg ms "${PR_STATE:-unstable}" '{
    number: 7, state: "open", draft: false, title: "feat: something", merged: false, mergeable_state: $ms,
    updated_at: $u, html_url: "https://github.com/\($r)/pull/7",
    head: {ref: $ref, sha: $h, repo: {full_name: $r}}, base: {ref: "develop", repo: {full_name: $r}}}')"
  fake_route "repos/$R/pulls?state=open&per_page=100" "$(json_array "$pr")"
  fake_route "repos/$R/pulls/7" "$pr"
  fake_route "repos/$R/issues/7/comments?per_page=100" "$(json_array \
    "$(gh_comment 1 'github-actions[bot]' NONE "CI 检查没通过。"$'\n\n'"$(m6_marker "$H" ci)" "$at")" "${@:3}")"
}

sweep() { run bash "$REPO_ROOT/scripts/pr-sweep.sh"; }

assert_handed_once() {
  assert_called "curl" 1
  assert_called "gh api POST repos/$R/issues/7/comments" 1
  assert_contains "$(fake_last_body "gh api POST repos/$R/issues/7/comments")" "$STALE_MARKER"
  assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" "alerted $R#7 reason=ci-stale"
  refute_contains "$output" "CI 红，已停车"
}

@test "a red PR on a non-agent branch parked 25 hours is handed to a person once; the next round neither repeats it nor logs it" {
  red_pr topic $((25 * 3600))
  sweep
  assert_equal "$status" 0
  assert_handed_once
  body="$(fake_last_body "gh api POST repos/$R/issues/7/comments")"
  assert_contains "$body" "停了超过 24 小时没人动"

  # 第二轮：上一轮那条告警就在 PR 上（它也刷新了 updated_at，这里不管它，照样当作 25 小时）。
  : >"$FAKE_LOG"
  : >"$GITHUB_STEP_SUMMARY"
  red_pr topic $((25 * 3600)) "$(gh_comment 2 Melodymaifafa OWNER "$body" "2026-09-18T11:59:00Z")"
  sweep
  assert_equal "$status" 0
  refute_called "gh api POST"
  refute_called "curl"
  refute_contains "$output" "$R#7"
  refute_contains "$(cat "$GITHUB_STEP_SUMMARY")" "$R#7"
}

@test "parked 23 hours: still only the parked line, nothing written" {
  red_pr topic $((23 * 3600))
  sweep
  assert_equal "$status" 0
  refute_called "gh api POST"
  refute_called "curl"
  assert_contains "$output" "CI 红，已停车"
}

@test "the 24 hours are strict: exactly 24 hours waits, one second more is handed over" {
  red_pr topic 86400
  sweep
  refute_called "gh api POST"
  red_pr topic 86401
  sweep
  assert_handed_once
}

@test "an agent/* PR quiet for 25 hours with red CI is handed over the same way" {
  red_pr agent/mel-7 $((25 * 3600))
  sweep
  assert_equal "$status" 0
  assert_handed_once
}

@test "the marker is per head: a ci-stale on an older head does not stop the alert for the new one" {
  red_pr topic $((25 * 3600)) \
    "$(gh_comment 2 Melodymaifafa OWNER "老的。"$'\n\n'"$(m6_marker "$OTHER" ci-stale)" "2026-09-16T12:00:00Z")"
  sweep
  assert_equal "$status" 0
  assert_handed_once
}

@test "after the alert, CI going green brings the PR back to the normal rules" {
  PR_STATE=clean red_pr topic $((25 * 3600)) "$(gh_comment 2 Melodymaifafa OWNER "$STALE_MARKER" "2026-09-17T11:00:00Z")"
  sweep
  assert_equal "$status" 0
  assert_contains "$output" "$R#7"
  refute_contains "$output" "CI 红，已停车"
}
