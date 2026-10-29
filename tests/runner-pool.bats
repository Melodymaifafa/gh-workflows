#!/usr/bin/env bats
# 本机 runner 池（scripts/runner-pool.sh）的取舍：哪个仓库补空闲 runner、哪个容器收掉。

load test_helper/common

setup() {
  # shellcheck source=../scripts/runner-pool.sh
  . "$REPO_ROOT/scripts/runner-pool.sh"
  repos="$BATS_TEST_TMPDIR/repos"
  printf '%s\n' content-grabbers wf-smoke-test >"$repos"
}

@test "a repo without an idle runner gets one, a repo with one does not" {
  out="$(printf '%s\n' 'ghwf-wf-smoke-test-1 wf-smoke-test idle' | decide "$repos" 4)"
  assert_equal "$out" "spawn content-grabbers"
}

@test "a busy runner does not count as the repo's idle one" {
  out="$(printf '%s\n' 'ghwf-content-grabbers-1 content-grabbers busy' 'ghwf-wf-smoke-test-1 wf-smoke-test idle' | decide "$repos" 4)"
  assert_equal "$out" "spawn content-grabbers"
}

@test "at the cap with nothing idle to take, repos wait" {
  out="$(printf '%s\n' 'a content-grabbers busy' 'b wf-smoke-test busy' | decide "$repos" 2)"
  assert_equal "$out" "full content-grabbers
full wf-smoke-test"
}

@test "at the cap a repo with a job running takes the idle runner of a repo with none" {
  printf '%s\n' hot cold >"$repos"
  out="$(printf '%s\n' 'h1 hot busy' 'c1 cold idle' | decide "$repos" 2)"
  assert_equal "$out" "reclaim c1 hot"
}

@test "at the cap a repo with no job running does not take anyone's runner" {
  printf '%s\n' hot cold cold2 >"$repos"
  out="$(printf '%s\n' 'h1 hot busy' 'h2 hot idle' 'c1 cold idle' | decide "$repos" 3)"
  assert_equal "$out" "full cold2"
}

@test "one idle runner is reclaimed once, not for two repos" {
  printf '%s\n' hotA hotB cold >"$repos"
  out="$(printf '%s\n' 'a hotA busy' 'b hotB busy' 'c cold idle' | decide "$repos" 3)"
  assert_equal "$out" "reclaim c hotA
full hotB"
}

@test "a runner already being removed is not reclaimed again" {
  printf '%s\n' new hot >"$repos"
  out="$(printf '%s\n' 'o old idle' 'h hot busy' | decide "$repos" 2)"
  assert_equal "$out" "remove o
full new
full hot"
}

@test "an idle runner removed for a dropped repo frees its room only on the next tick" {
  printf '%s\n' r1 >"$repos"
  out="$(printf '%s\n' 'x old idle' | decide "$repos" 1)"
  assert_equal "$out" "remove x
full r1"
}

@test "spawns in one tick stop at the remaining room" {
  printf '%s\n' r1 r2 r3 r4 >"$repos"
  out="$(printf '%s\n' 'a r0 busy' 'b r0 busy' | decide "$repos" 4)"
  assert_equal "$out" "spawn r1
spawn r2
full r3
full r4"
}

@test "an idle runner of a repo that dropped GHWF_RUNNER is removed, a busy one is left to finish" {
  out="$(printf '%s\n' 'ghwf-old-1 old-repo idle' 'ghwf-old-2 old-repo busy' 'c content-grabbers idle' 'w wf-smoke-test idle' | decide "$repos" 4)"
  assert_equal "$out" "remove ghwf-old-1"
}

@test "repo names are matched whole, not as a substring of another repo" {
  printf '%s\n' grabbers >"$repos"
  out="$(printf '%s\n' 'ghwf-content-grabbers-1 content-grabbers idle' | decide "$repos" 4)"
  assert_contains "$out" "spawn grabbers"
}

@test "no runners at all: every listed repo gets one" {
  out="$(printf '' | decide "$repos" 4)"
  assert_equal "$out" "spawn content-grabbers
spawn wf-smoke-test"
}

@test "a failed docker ps skips the tick instead of starting a runner for every repo" {
  state="$BATS_TEST_TMPDIR"  # $repos 已经在这里，名字正好是 tick 要读的 repos
  docker() { [ "$1" = ps ] && return 1; return 0; }
  spawn() { echo "spawned $1"; }
  run tick
  [ "$status" -eq 0 ]
  refute_contains "$output" "spawned"
  assert_contains "$output" "列不出池里的容器"
}

@test "an idle runner on an old image is removed and its repo gets a new one" {
  printf '%s\n' r1 >"$repos"
  out="$(printf '%s\n' 'old1 r1 stale' | decide "$repos" 4)"
  assert_equal "$out" "remove old1
spawn r1"
}

@test "list_runners marks idle runners on an old image stale, and leaves busy ones busy" {
  docker() {
    case "$1" in
      ps) printf '%s\n' 'a r1 ghwf-runner:old' "b r1 $image" 'c r2 ghwf-runner:old' ;;
      logs) [ "$2" = c ] && echo "Running job: ci" ;;
    esac
    return 0
  }
  out="$(list_runners)"
  assert_equal "$out" "a r1 stale
b r1 idle
c r2 busy"
}

# pm2 的日志以前一行时间都没有（MEL-517：runner 池日志 1120 行，一个时间都没有）。直接跑时 stdout、
# stderr 每行开头都是日期时间；被 source 时（上面这些测试）不接管输出。
@test "run directly, every stdout and stderr line starts with the date and time" {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  # docker 连不上：打一行 stdout（启动 colima）、一行 stderr（告警）；sleep 退出，循环只走一圈。
  printf '%s\n' '#!/bin/sh' 'exit 1' >"$bin/docker"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$bin/colima"
  printf '%s\n' '#!/bin/sh' 'echo "sleep err" >&2' 'exit 1' >"$bin/sleep"
  chmod +x "$bin/docker" "$bin/colima" "$bin/sleep"
  run_split "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/err" \
    env PATH="$bin:$PATH" RUNNER_POOL_STATE="$BATS_TEST_TMPDIR/state" GH_WORKFLOWS_SECRETS="$BATS_TEST_TMPDIR/none" \
    bash "$REPO_ROOT/scripts/runner-pool.sh"
  assert_stamped "$BATS_TEST_TMPDIR/out"
  assert_stamped "$BATS_TEST_TMPDIR/err"
  assert_contains "$(cat "$BATS_TEST_TMPDIR/out")" '连不上 colima 里的 docker'
  assert_contains "$(cat "$BATS_TEST_TMPDIR/err")" 'colima 里的 docker 起不来'
  assert_contains "$(cat "$BATS_TEST_TMPDIR/err")" ' sleep err'
}
