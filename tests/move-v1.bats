#!/usr/bin/env bats
# 每天自动移 v1（scripts/move-v1.sh）：只往前挪到 develop 上 CI 全绿的最新提交；移了推一条
# 带回滚办法的通知；方向不对、找不到绿提交、缺令牌都不动。手动指定 to 可以往回退。
# shellcheck disable=SC2030,SC2031  # bats 每个 @test 是子 shell

load test_helper/common

MOVE=scripts/move-v1.sh
V1=1111111111111111111111111111111111111111
G=2222222222222222222222222222222222222222
OLD=0000000000000000000000000000000000000000
GREEN='repos/o/r/actions/workflows/self-ci.yml/runs?branch=develop&event=push&status=success&per_page=1'

setup() {
  setup_fake_env
  export REPO=o/r GH_TOKEN=read-token WRITE_TOKEN=write-token TO='' DRY_RUN=false UNATTENDED=true
  export PUSHOVER_TOKEN=pt PUSHOVER_USER=pu
  fake_route repos/o/r/git/ref/tags/v1 "{\"object\":{\"sha\":\"$V1\"}}"
  fake_route "$GREEN" "{\"workflow_runs\":[{\"head_sha\":\"$G\"}]}"
  fake_route "repos/o/r/compare/$G...develop" '{"status":"identical"}'
  compare "$V1" "$G" ahead 'feat: one (#58)' 'fix: two (#60)'
}

compare() { # compare <base> <head> <status> [提交标题...]
  local base="$1" head="$2" status="$3"
  shift 3
  fake_route "repos/o/r/compare/$base...$head" "$(printf '%s\n' "$@" |
    jq -R . | jq -s --arg s "$status" '{status: $s, commits: [.[] | select(. != "") | {commit: {message: (. + "\n\nbody")}}]}')"
}

move() { run "$REPO_ROOT/$MOVE"; }

@test "moves v1 forward to the newest green develop commit, with the write token only" {
  move
  assert_equal "$status" 0
  assert_called "gh api PATCH repos/o/r/git/refs/tags/v1" 1
  assert_contains "$(fake_calls 'PATCH repos/o/r/git/refs/tags/v1')" "sha=$G"
  assert_contains "$(fake_calls 'PATCH repos/o/r/git/refs/tags/v1')" 'force=true'
  assert_contains "$(fake_calls 'PATCH repos/o/r/git/refs/tags/v1')" '[token=write-token]'
  # 读的那几次都用 job 自带的令牌
  refute_contains "$(fake_calls 'GET')" 'write-token'
  # 通知说清带了哪些 PR、怎么回滚
  assert_called 'curl ' 1
  push="$(fake_last_body 'curl ')"
  assert_contains "$push" '- feat: one (#58)'
  assert_contains "$push" '- fix: two (#60)'
  assert_contains "$push" 'to 填 1111111'
}

@test "already at the newest green commit: nothing moves, nobody is pinged" {
  fake_route "$GREEN" "{\"workflow_runs\":[{\"head_sha\":\"$V1\"}]}"
  move
  assert_equal "$status" 0
  assert_contains "$output" '不用动'
  refute_called 'PATCH'
  refute_called 'curl '
}

# 有人手动把 v1 挪到了更新的位置或者别的线上：自动这一步不往回拽，推一条等人看。
@test "a green commit that is not ahead of v1 is left alone and reported" {
  for s in behind diverged; do
    : >"$FAKE_LOG"
    compare "$V1" "$G" "$s"
    move
    assert_equal "$status" 0
    refute_called 'PATCH'
    assert_called 'curl ' 1
    assert_contains "$(fake_last_body 'curl ')" "相对它是 $s"
  done
}

# develop 被强推过、新 CI 还没绿：最新那条绿记录指的旧提交已经不在 develop 上，哪怕它在 v1 前面也不跟。
@test "a green commit that has fallen off develop is left alone and reported" {
  for s in diverged behind; do
    : >"$FAKE_LOG"
    fake_route "repos/o/r/compare/$G...develop" "{\"status\":\"$s\"}"
    move
    assert_equal "$status" 0
    refute_called 'PATCH'
    assert_called 'curl ' 1
    assert_contains "$(fake_last_body 'curl ')" "相对 develop 是 $s"
  done
}

@test "no green develop commit: nothing moves" {
  fake_route "$GREEN" '{"workflow_runs":[]}'
  move
  assert_equal "$status" 0
  refute_called 'PATCH'
  assert_contains "$output" '找不到 CI 全绿的提交'
}

@test "a dry run says where v1 would go and moves nothing" {
  export DRY_RUN=true
  move
  assert_equal "$status" 0
  assert_contains "$output" '会把 v1 从 `1111111` 移到 `2222222`（2 个提交，没有真的移）'
  refute_called 'PATCH'
  refute_called 'curl '
}

@test "a manual run can roll v1 back to an older develop commit" {
  export TO=000000 UNATTENDED=false
  fake_route repos/o/r/commits/000000 "{\"sha\":\"$OLD\"}"
  fake_route "repos/o/r/compare/$OLD...develop" '{"status":"ahead"}'
  compare "$V1" "$OLD" behind
  compare "$OLD" "$V1" ahead 'feat: bad (#61)'
  move
  assert_equal "$status" 0
  assert_contains "$(fake_calls 'PATCH repos/o/r/git/refs/tags/v1')" "sha=$OLD"
  assert_contains "$output" '退回到 `0000000`'
  assert_contains "$output" '- feat: bad (#61)'
}

@test "a rollback target that is not on develop is refused" {
  export TO=000000
  fake_route repos/o/r/commits/000000 "{\"sha\":\"$OLD\"}"
  fake_route "repos/o/r/compare/$OLD...develop" '{"status":"diverged"}'
  move
  assert_equal "$status" 1
  refute_called 'PATCH'
  assert_contains "$output" '不在 develop 这条线上（diverged）'
}

@test "without the write token nothing moves and the run goes red" {
  export WRITE_TOKEN=''
  move
  assert_equal "$status" 1
  refute_called 'PATCH'
  assert_contains "$(fake_last_body 'curl ')" 'SELF_WORKFLOWS_TOKEN 没设'
}

@test "workflow: runs daily and hands the write token only to the move step" {
  wf="$(cat "$REPO_ROOT/.github/workflows/move-v1.yml")"
  assert_contains "$wf" "- cron: '47 1 * * *'"
  assert_equal "$(step_env_keys .github/workflows/move-v1.yml 'Keep the schedule alive' | grep -c WRITE_TOKEN)" 0
  assert_contains "$(step_env_keys .github/workflows/move-v1.yml 'Move v1 to the newest green develop commit')" WRITE_TOKEN
}

# 手动跑时选了别的分支：那边的 workflow / 脚本没人审过，走不到拿令牌那一步。
@test "workflow: a manual run from another branch stops before the write token is handed out" {
  wf="$REPO_ROOT/.github/workflows/move-v1.yml"
  guard='Only run the version on the default branch'
  # 第一步就是它（在 checkout 之前），只拦手动跑、只放默认分支
  assert_equal "$(grep -m1 '^      - ' "$wf")" "      - name: $guard"
  assert_contains "$(cat "$wf")" "if: github.event_name == 'workflow_dispatch' && github.ref != format('refs/heads/{0}', github.event.repository.default_branch)"
  refute_contains "$(step_env_keys "$wf" "$guard")" WRITE_TOKEN
  export RUN_REF=refs/heads/topic DEFAULT_BRANCH=main
  run run_step "$wf" "$guard"
  assert_equal "$status" 1
  assert_contains "$output" '只能在默认分支 main 上跑，这次选的是 refs/heads/topic'
}
