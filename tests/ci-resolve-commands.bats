#!/usr/bin/env bats
# ci.yml 的测试：「Resolve commands」那段 runtime→命令映射，外加「lint 挂住时要红得
# 出来」那几道（MEL-291）。这条流水线是所有仓库共用的分发口：改错了不是一个仓库红，
# 是全部一起红 —— 挂住更糟，连红都没有。

load test_helper/common

@test "python runtime resolves to the uv toolchain" {
  resolve_commands python
  assert_equal "$(resolved INSTALL_CMD)" 'uv sync --dev'
  assert_equal "$(resolved LINT_CMD)" 'uv run ruff check .'
  assert_equal "$(resolved TEST_CMD)" 'uv run pytest'
}

@test "node runtime resolves to npm and tolerates a missing test script" {
  resolve_commands node
  assert_equal "$(resolved LINT_CMD)" 'npm run lint --if-present'
  assert_equal "$(resolved TEST_CMD)" 'npm run test --if-present'
}

@test "unknown runtime fails instead of silently passing" {
  run resolve_commands rust
  assert_equal "$status" 1
  assert_contains "$output" "unknown runtime 'rust'"
}

@test "caller overrides win over the runtime defaults" {
  TEST_OVERRIDE=skip resolve_commands python
  assert_equal "$(resolved TEST_CMD)" skip
  assert_equal "$(resolved INSTALL_CMD)" 'uv sync --dev'
}

@test "shell runtime installs a pinned bats, never a floating ref" {
  resolve_commands shell
  install_cmd="$(resolved INSTALL_CMD)"
  assert_contains "$install_cmd" 'bats-core'
  assert_contains "$install_cmd" '/tags/v1.'
  refute_contains "$install_cmd" 'latest'
  refute_contains "$install_cmd" 'main.tar.gz'
}

@test "shell runtime skips quietly in a repo with no bats tests" {
  resolve_commands shell
  test_cmd="$(resolved TEST_CMD)"
  cd "$BATS_TEST_TMPDIR"                       # 空目录 = 没有 tests/ 的仓库
  run bash -c "$test_cmd"
  assert_equal "$status" 0
  assert_contains "$output" 'no bats tests'
}

@test "shell runtime runs bats in a repo that has them" {
  resolve_commands shell
  test_cmd="$(resolved TEST_CMD)"
  mkdir -p "$BATS_TEST_TMPDIR/tests"
  printf '@test "sanity" {\n  [ 1 -eq 1 ]\n}\n' >"$BATS_TEST_TMPDIR/tests/sanity.bats"
  cd "$BATS_TEST_TMPDIR"
  run bash -c "$test_cmd"
  assert_equal "$status" 0
  assert_contains "$output" 'ok 1 sanity'
}

# ---------- lint 挂住的时候要红得出来，而不是一声不响挂满 6 小时（MEL-291） ----------

# actionlint 对每个 run: 块自动跑 shellcheck，块是写进那个进程 stdin 的；一超过 64 KiB
# 管道缓冲就两头互等，actionlint 既不报错也不退出。job 没有超时时 GitHub 要到 360 分钟
# 上限才收，19 个调用方仓库看到的就是「CI 一直转」而不是红叉。超时让它红得出来。
@test "the lint step has a timeout so a hung linter goes red instead of running to the job cap" {
  minutes="$(step_key "$CI_WORKFLOW" Lint timeout-minutes)"
  [ -n "$minutes" ] || {
    echo 'the Lint step declares no timeout-minutes; a deadlocked linter would hang to the 360-minute job cap' >&2
    return 1
  }
  [ "$minutes" -le 60 ] || {
    echo "the Lint timeout is $minutes minutes, too close to the 360-minute job cap to be a backstop" >&2
    return 1
  }
}

# 上面那条超时是兜底，这条是正门：超长的块在本机 `bats tests/` 就红，附带说清要怎么改。
# 真走到 actionlint 那一步已经看不出发生了什么 —— 没有输出、没有退出码、只有一个卡住的
# 进程。实测的门槛是 65,338 字节过、65,500 左右死锁，这里取 64,000 留一截余量。
@test "no run: block comes close to the 64 KiB pipe buffer that deadlocks actionlint" {
  max=64000
  over=''
  while read -r bytes where; do
    [ -n "$bytes" ] || continue
    [ "$bytes" -lt "$max" ] && continue
    over="$over  $where: $bytes bytes"$'\n'
  done < <(run_block_sizes)
  [ -z "$over" ] || {
    printf 'these run: blocks are at or past %s bytes and will deadlock actionlint; split each into separate steps:\n%s' \
      "$max" "$over" >&2
    return 1
  }
}
