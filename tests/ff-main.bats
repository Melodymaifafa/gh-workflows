#!/usr/bin/env bats
# ff-main.yml 的 CI 闸门只认真测过落点的 check run：
# - 本次 run 自己的不算。落点是 develop 最新提交时（天数填 0），它就挂在落点上 —— 不排除就永远
#   挪不了（2026-09-29 linear-agent-team 实测：CI 早已全绿，仍报「1 项未完成」）。
# - 合并、快进这些流水线 job 不算。它们由 PR 事件 / 评论 / 定时触发，GitHub 把它们挂在默认分支
#   最新提交上，不是测过它（2026-10-07 wechat-mimic-finetune fa97fd0：只挂着合并 run，其中一条
#   cancelled）。

# 字面量 ${{ }} 是 step 名；bats 每个 @test 是子 shell。
# shellcheck disable=SC2016,SC2030,SC2031

load test_helper/common

WF=.github/workflows/ff-main.yml
STEP='Move ${{ inputs.target }} to ${{ inputs.source }}'
GOAL=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
OWN_RUN=424242
CHECKS="repos/o/r/commits/$GOAL/check-runs?per_page=100"

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
  fake_route "$CHECKS" "$(check_runs \
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
  fake_route "$CHECKS" "$(check_runs \
    "$(check_run "$OWN_RUN" 'fast-forward / fast-forward' in_progress '')" \
    "$(check_run 777 'ci / lint-and-test' in_progress '')")"

  run run_block "$WF" "$STEP"

  assert_equal "$status" 0
  assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" 'CI 还在跑（1 项未完成）'
  refute_called "git/refs/heads/main"
}

@test "green gate: a goal that carries only the run's own check has no CI record" {
  fake_route "$CHECKS" "$(check_runs \
    "$(check_run "$OWN_RUN" 'fast-forward / fast-forward' in_progress '')")"

  run run_block "$WF" "$STEP"

  assert_equal "$status" 0
  assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" '没有任何 CI 记录'
  refute_called "git/refs/heads/main"
}

# GitHub 给可复用工作流的 check run 起名「调用方 job / 被调用方 job」；前半截各仓库自己定。
@test "green gate: merge-workflow checks neither count as CI nor block it" {
  fake_route "$CHECKS" "$(check_runs \
    "$(check_run 501 'merge / watch-and-merge' completed success)" \
    "$(check_run 501 'merge / claude-review' completed skipped)" \
    "$(check_run 502 'merge / watch-and-merge' completed cancelled)" \
    "$(check_run 777 'ci / lint-and-test' completed success)")"

  run run_block "$WF" "$STEP"

  assert_equal "$status" 0
  assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" 'CI 全绿（1 项）'
  assert_called "git/refs/heads/main" 1
}

@test "green gate: a goal that carries only merge-workflow checks has no CI record" {
  fake_route "$CHECKS" "$(check_runs \
    "$(check_run 501 'merge / watch-and-merge' completed success)" \
    "$(check_run 502 'automerge / watch-and-merge' completed cancelled)" \
    "$(check_run 502 'automerge / claude-review' completed skipped)")"

  run run_block "$WF" "$STEP"

  assert_equal "$status" 0
  assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" '没有任何 CI 记录'
  refute_called "git/refs/heads/main"
}

# 定时快进挂在当时的最新提交上；两周后它成了泡够天数的落点，那条旧绿勾不能冒充 CI。
@test "green gate: an earlier fast-forward run on the goal is not CI either" {
  fake_route "$CHECKS" "$(check_runs \
    "$(check_run 300 'fast-forward / fast-forward' completed success)")"

  run run_block "$WF" "$STEP"

  assert_equal "$status" 0
  assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" '没有任何 CI 记录'
  refute_called "git/refs/heads/main"
}

@test "green gate: a real CI failure still holds the move" {
  fake_route "$CHECKS" "$(check_runs \
    "$(check_run 501 'merge / watch-and-merge' completed success)" \
    "$(check_run 777 'ci / lint-and-test' completed failure)")"

  run run_block "$WF" "$STEP"

  assert_equal "$status" 0
  assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" 'CI 没全绿（1 项失败）'
  refute_called "git/refs/heads/main"
}

# 排除名单是写死的 job key。合并 / 快进工作流改了 job 名或新加 job，这里就红 ——
# 不然新 job 的 cancelled 又会把 develop 卡住。
@test "green gate: every job of the merge and fast-forward workflows is excluded" {
  local keys=() key
  while IFS= read -r key; do keys+=("$key"); done < <(
    awk 'FNR == 1 {on = 0} /^jobs:/{on=1; next} on && /^  [A-Za-z0-9_-]+:$/{sub(/^  /,""); sub(/:$/,""); print}' \
      "$REPO_ROOT/.github/workflows/codex-approved-merge.yml" "$REPO_ROOT/.github/workflows/ff-main.yml"
  )
  assert_equal "${#keys[@]}" 3
  for key in "${keys[@]}"; do
    rm -rf "$FAKE_DIR"; setup
    fake_route "$CHECKS" "$(check_runs \
      "$(check_run 501 "caller / $key" completed cancelled)" \
      "$(check_run 777 'ci / lint-and-test' completed success)")"

    run run_block "$WF" "$STEP"

    assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" 'CI 全绿（1 项）'
  done
}
