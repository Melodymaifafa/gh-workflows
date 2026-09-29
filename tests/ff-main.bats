#!/usr/bin/env bats
# ff-main.yml 的 CI 闸门：本次 run 自己的 check run 不算「还在跑」，别人的才算。
# 落点是 develop 最新提交时（天数填 0），自己的 check run 就挂在落点上 —— 不排除就永远挪不了
# （2026-09-29 linear-agent-team 实测：CI 早已全绿，仍报「1 项未完成」）。

# 字面量 ${{ }} 是 step 名；bats 每个 @test 是子 shell。
# shellcheck disable=SC2016,SC2030,SC2031

load test_helper/common

WF=.github/workflows/ff-main.yml
STEP='Move ${{ inputs.target }} to ${{ inputs.source }}'
GOAL=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
OWN_RUN=424242

# check_run <run-id> <name> <status> <conclusion|''>：一条 GitHub Actions 的 check run。
check_run() {
  jq -cn --arg run "$1" --arg name "$2" --arg status "$3" --arg conclusion "$4" '
    {name: $name, status: $status,
     conclusion: (if $conclusion == "" then null else $conclusion end),
     details_url: ("https://github.com/o/r/actions/runs/" + $run + "/job/1")}'
}

# check_runs <json>...：落点上的 check-runs 列表。
check_runs() {
  printf '%s\n' "$@" | jq -cs '{check_runs: .}'
}

setup() {
  setup_fake_env
  export REPO=o/r SOURCE=develop TARGET=main MIN_AGE_DAYS=0 REQUIRE_GREEN=true DRY_RUN=false
  export UNATTENDED=false GH_TOKEN=t GITHUB_RUN_ID="$OWN_RUN"
  fake_route repos/o/r/git/ref/heads/develop "{\"object\":{\"sha\":\"$GOAL\"}}"
  fake_route repos/o/r/git/ref/heads/main "{\"object\":{\"sha\":\"$OLD\"}}"
  fake_route "repos/o/r/compare/main...$GOAL" '{"status":"ahead","ahead_by":3,"behind_by":0,"commits":[]}'
  fake_route -X PATCH repos/o/r/git/refs/heads/main '{}'
}

@test "green gate: the run's own in-progress check does not count as CI still running" {
  fake_route "repos/o/r/commits/$GOAL/check-runs" "$(check_runs \
    "$(check_run "$OWN_RUN" 'fast-forward / fast-forward' in_progress '')" \
    "$(check_run 777 'ci / lint-and-test' completed success)")"

  run run_block "$WF" "$STEP"

  assert_equal "$status" 0
  summary="$(cat "$GITHUB_STEP_SUMMARY")"
  assert_contains "$summary" 'CI 全绿（1 项）'
  assert_contains "$summary" '已前移 3 个 commit'
  assert_called "git/refs/heads/main" 1
}

@test "green gate: somebody else's in-progress check still holds the move" {
  fake_route "repos/o/r/commits/$GOAL/check-runs" "$(check_runs \
    "$(check_run "$OWN_RUN" 'fast-forward / fast-forward' in_progress '')" \
    "$(check_run 777 'ci / lint-and-test' in_progress '')")"

  run run_block "$WF" "$STEP"

  assert_equal "$status" 0
  assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" 'CI 还在跑（1 项未完成）'
  refute_called "git/refs/heads/main"
}

@test "green gate: a goal that carries only the run's own check has no CI record" {
  fake_route "repos/o/r/commits/$GOAL/check-runs" "$(check_runs \
    "$(check_run "$OWN_RUN" 'fast-forward / fast-forward' in_progress '')")"

  run run_block "$WF" "$STEP"

  assert_equal "$status" 0
  assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" '没有任何 CI 记录'
  refute_called "git/refs/heads/main"
}
