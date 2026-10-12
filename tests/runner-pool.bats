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

@test "at MAX_BUSY busy jobs nothing new starts" {
  out="$(printf '%s\n' 'a content-grabbers busy' 'b content-grabbers busy' | decide "$repos" 2)"
  assert_equal "$out" "full content-grabbers
full wf-smoke-test"
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
