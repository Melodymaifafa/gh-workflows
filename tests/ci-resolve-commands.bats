#!/usr/bin/env bats
# ci.yml「Resolve commands」那段 runtime→命令映射的测试。
# 这段是所有仓库共用的分发口：改错了不是一个仓库红，是全部一起红。

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
