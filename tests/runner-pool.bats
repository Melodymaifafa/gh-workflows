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
  assert_equal "$out" "reclaim c1
spawn hot"
}

@test "at the cap a repo with no job running does not take anyone's runner" {
  printf '%s\n' hot cold cold2 >"$repos"
  out="$(printf '%s\n' 'h1 hot busy' 'h2 hot idle' 'c1 cold idle' | decide "$repos" 3)"
  assert_equal "$out" "full cold2"
}

@test "one idle runner is reclaimed once, not for two repos" {
  printf '%s\n' hotA hotB cold >"$repos"
  out="$(printf '%s\n' 'a hotA busy' 'b hotB busy' 'c cold idle' | decide "$repos" 3)"
  assert_equal "$out" "reclaim c
spawn hotA
full hotB"
}

@test "a runner already being removed is not reclaimed again" {
  printf '%s\n' new hot >"$repos"
  out="$(printf '%s\n' 'o old idle' 'h hot busy' | decide "$repos" 2)"
  assert_equal "$out" "remove o
spawn new
full hot"
}

@test "an idle runner removed for a dropped repo frees its room" {
  printf '%s\n' r1 >"$repos"
  out="$(printf '%s\n' 'x old idle' | decide "$repos" 1)"
  assert_equal "$out" "remove x
spawn r1"
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
