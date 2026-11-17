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

# recycle_vm 的假环境：虚拟机开了 $1 秒，池里是 $2 这几行，docker ps -q 一共 $3 个容器。
# 每次 docker rm / colima restart 记到 $calls。
fake_vm() {
  calls="$BATS_TEST_TMPDIR/calls"
  : >"$calls"
  vm_up="$1" pool_rows="$2" container_count="$3"
  colima() {
    case "$1" in
      ssh) [ -n "$vm_up" ] && echo "$vm_up" ;;
      restart) echo "colima restart" >>"$calls" ;;
    esac
  }
  list_runners() { [ -z "$pool_rows" ] || printf '%s\n' "$pool_rows"; }
  took_job() { [ "$1" = "${takes_job:-}" ]; }
  docker() {
    case "$1" in
      ps) [ "$container_count" -eq 0 ] || seq "$container_count" ;;
      rm) echo "docker rm $3" >>"$calls" ;;
    esac
  }
}

@test "a VM up for a week with only idle runners: they are removed, then it restarts" {
  fake_vm $((8 * 86400)) 'a r1 idle
b r2 stale' 2
  run recycle_vm
  [ "$status" -eq 0 ]
  assert_equal "$(cat "$calls")" "docker rm a
docker rm b
colima restart"
}

@test "a VM up for less than RESTART_DAYS is left alone" {
  fake_vm $((6 * 86400)) 'a r1 idle' 1
  run recycle_vm
  [ "$status" -eq 1 ]
  assert_equal "$(cat "$calls")" ""
}

@test "a job is running: no restart, and the idle runners stay" {
  fake_vm $((8 * 86400)) 'a r1 idle
b r2 busy' 2
  run recycle_vm
  [ "$status" -eq 1 ]
  assert_equal "$(cat "$calls")" ""
}

@test "a container from outside the pool is running: no restart" {
  fake_vm $((8 * 86400)) 'a r1 idle' 2
  run recycle_vm
  [ "$status" -eq 1 ]
  assert_equal "$(cat "$calls")" ""
}

@test "an idle runner that picks up a job before it is removed stops the restart" {
  fake_vm $((8 * 86400)) 'a r1 idle
b r2 idle' 2
  takes_job=b
  run recycle_vm
  [ "$status" -eq 1 ]
  assert_equal "$(cat "$calls")" "docker rm a"
}

@test "an unreadable VM uptime means no restart" {
  fake_vm '' 'a r1 idle' 1
  run recycle_vm
  [ "$status" -eq 1 ]
  assert_equal "$(cat "$calls")" ""
}

@test "an empty pool on an old VM still restarts" {
  fake_vm $((8 * 86400)) '' 0
  run recycle_vm
  [ "$status" -eq 0 ]
  assert_equal "$(cat "$calls")" "colima restart"
}
