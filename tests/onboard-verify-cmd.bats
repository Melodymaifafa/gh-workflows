#!/usr/bin/env bats
# onboard.sh 写进 iterate 调用桩的 verify_cmd（MEL-303）。
#
# 仓库用 install_cmd / lint_cmd / test_cmd 覆盖掉 ci.yml 的默认命令时，修复那一轮
# 的验证命令必须跟着覆盖。不跟着覆盖的代价是单向的：CI 跑的是仓库自己给的命令所以
# 绿着，修复那一轮跑的是中央仓库的默认命令、而那套命令正是这个仓库装不上的 ——
# 于是「改好了但验证没过」成了常态（MEL-293 的另一半）。

load test_helper/common

# ---------- 没覆盖 → 桩里不写，让中央仓库的默认值生效 ----------

@test "no override: the iterate stub carries no active verify_cmd" {
  onboard_render python
  stub="$(rendered_stub claude-codex-iterate.yml)"
  refute_contains "$stub" $'\n      verify_cmd:'
  refute_contains "$stub" '__VERIFY_CMD__'
}

@test "no override: the ci stub carries no install/lint/test either" {
  onboard_render python
  stub="$(rendered_stub ci.yml)"
  refute_contains "$stub" 'install_cmd:'
  refute_contains "$stub" 'test_cmd:'
  refute_contains "$stub" '__OVERRIDES__'
}

# ci.yml 的 Resolve commands 把 INSTALL_CMD / LINT_CMD / TEST_CMD 写进 $GITHUB_ENV，
# 所以这个套件在 CI 里跑的时候，环境里本来就有这三个值（装 actionlint、跑 bats 那套）。
# 渲染必须只看测试给的值，不看环境里捡到的 —— 否则上面那两条「没传覆盖值」本机绿、
# CI 红，而红的是测试不是产品，最难看懂。
@test "the CI job's own INSTALL_CMD in the environment does not leak into the rendering" {
  export INSTALL_CMD='leaked-install' LINT_CMD='leaked-lint' TEST_CMD='leaked-test' RUNS_ON='leaked-runner'
  onboard_render python
  refute_contains "$(rendered_stub ci.yml)" leaked
  refute_contains "$(rendered_stub claude-codex-iterate.yml)" leaked
  refute_contains "$(rendered_stub claude-codex-iterate.yml)" $'\n      verify_cmd:'
}

# ---------- 给了覆盖值 → 桩里有对应的 verify_cmd ----------

@test "all three overridden: verify_cmd is those three commands, one per line" {
  OV_INSTALL='make deps' OV_LINT='make lint' OV_TEST='make test' onboard_render node
  assert_equal "$(rendered_verify_line 1)" 'make deps'
  assert_equal "$(rendered_verify_line 2)" 'make lint'
  assert_equal "$(rendered_verify_line 3)" 'make test'
  assert_equal "$(rendered_verify_line 4)" ''
}

@test "the override also lands in ci.yml, so both sides say the same thing" {
  OV_INSTALL='make deps' OV_LINT='make lint' OV_TEST='make test' onboard_render node
  ci="$(rendered_stub ci.yml)"
  assert_contains "$ci" "install_cmd: 'make deps'"
  assert_contains "$ci" "lint_cmd: 'make lint'"
  assert_contains "$ci" "test_cmd: 'make test'"
}

# verify_cmd 是整份替换，不是逐行合并。只写被覆盖的那一条，另两条会从修复那一轮里
# 整个消失 —— 装依赖没了，后面两条必然红。这条是这张票最容易写错的地方。
@test "one override only: the other two lines are filled with ci.yml's defaults" {
  OV_TEST='pytest -x' onboard_render python
  assert_equal "$(rendered_verify_line 1)" 'uv sync --dev'
  assert_equal "$(rendered_verify_line 2)" 'uv run ruff check .'
  assert_equal "$(rendered_verify_line 3)" 'pytest -x'
}

@test "runs_on alone is not a verify command and writes no verify_cmd" {
  OV_RUNS_ON='macos-latest' onboard_render node
  refute_contains "$(rendered_stub claude-codex-iterate.yml)" $'\n      verify_cmd:'
  assert_contains "$(rendered_stub ci.yml)" "runs_on: 'macos-latest'"
}

# ---------- 填进去的默认值必须跟 ci.yml 逐字一样 ----------

# 第三份拷贝（ci.yml、中央 iterate、onboard.sh）就得有第三条判定钉住它。
# 差一个字的后果跟 MEL-293 一样：CI 绿着、修复那一轮必然红。
@test "pinned: the python defaults onboard fills in are ci.yml's, verbatim" {
  OV_TEST=skip onboard_render python
  line1="$(rendered_verify_line 1)"
  line2="$(rendered_verify_line 2)"
  resolve_commands python                      # 这一句会重写 $GITHUB_ENV，所以先读完上面
  assert_equal "$line1" "$(resolved INSTALL_CMD)"
  assert_equal "$line2" "$(resolved LINT_CMD)"
}

@test "pinned: the node defaults onboard fills in are ci.yml's, verbatim" {
  OV_INSTALL=skip onboard_render node
  line2="$(rendered_verify_line 2)"
  line3="$(rendered_verify_line 3)"
  resolve_commands node
  assert_equal "$line2" "$(resolved LINT_CMD)"
  assert_equal "$line3" "$(resolved TEST_CMD)"
  # MEL-293 的那两个坑不许从这条路漏回来
  refute_contains "$line3" 'npm test'
}

# 这一条不比「跟 ci.yml 一致」，它盯着 MEL-293 那个坑本身：没有 lockfile 的仓库
# 碰上裸 `npm ci` 直接失败，而 CI 绿着。免得哪天 ci.yml 先退化、两边一起错。
@test "pinned: the node install default survives a repo with no lockfile" {
  OV_TEST=skip onboard_render node
  install="$(rendered_verify_line 1)"
  assert_contains "$install" 'if [ -f package-lock.json ]'
  refute_contains "$install" 'npm ci || npm install'
}

# ---------- skip 的翻译 ----------

# ci.yml 的 skip 在那一步里是「打一条 notice 然后退出 0」。原样把 skip 写进
# verify_cmd 会被当成命令：找不到就 127，整轮红。
@test "skip becomes a notice, never the bare word skip" {
  OV_LINT=skip onboard_render python
  assert_equal "$(rendered_verify_line 2)" 'echo "::notice::lint skipped by caller"'
  run bash -euo pipefail -c "$(rendered_verify_line 2)"
  assert_equal "$status" 0
  assert_contains "$output" 'lint skipped by caller'
}

@test "skip on every line still leaves a non-empty verify_cmd" {
  OV_INSTALL=skip OV_LINT=skip OV_TEST=skip onboard_render node
  # 空的 verify_cmd 会让中央仓库判定「没有验证命令」、红着拒绝推送，
  # 于是这个仓库的修复一轮也走不完。三条 notice 跑得过，而且说得出跳了什么。
  assert_contains "$(rendered_verify_line 1)" 'install skipped by caller'
  assert_contains "$(rendered_verify_line 2)" 'lint skipped by caller'
  assert_contains "$(rendered_verify_line 3)" 'test skipped by caller'
  # 中央仓库是把整块当一个脚本跑的（bash -euo pipefail -c），所以整块也得跑得过。
  run bash -euo pipefail -c "$(printf '%s\n%s\n%s\n' \
    "$(rendered_verify_line 1)" "$(rendered_verify_line 2)" "$(rendered_verify_line 3)")"
  assert_equal "$status" 0
}

# 三条全 skip = 修复不经任何检查就推。接入这一刻不说，之后没人会再看生成的桩。
@test "skip on every line warns at onboard time that nothing gets verified" {
  OV_INSTALL=skip OV_LINT=skip OV_TEST=skip
  assert_contains "$(onboard_coverage_warning)" '都不会真验证任何东西'
}

@test "a repo that verifies something is not warned" {
  OV_INSTALL=skip OV_LINT=skip OV_TEST='pytest'
  assert_equal "$(onboard_coverage_warning)" ''
}

# ---------- 桩本身要说清这件事 ----------

@test "the shipped stub explains that verify_cmd must track ci.yml's overrides" {
  stub="$(cat "$REPO_ROOT/stubs/claude-codex-iterate.yml")"
  assert_contains "$stub" '# verify_cmd: |'
  assert_contains "$stub" 'install_cmd / lint_cmd / test_cmd'
  assert_contains "$stub" '__VERIFY_CMD__'
}

# ---------- 渲染出来的桩得是合法 YAML ----------

@test "the rendered iterate stub parses as YAML with verify_cmd as three lines" {
  OV_INSTALL='make deps' OV_LINT=skip OV_TEST='make test' onboard_render node
  run python3 -c '
import sys, pathlib
try:
    import yaml
except ImportError:
    sys.exit(99)
d = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
got = d["jobs"]["iterate"]["with"]["verify_cmd"].splitlines()
assert len(got) == 3, got
assert got[0] == "make deps", got
assert got[2] == "make test", got
print("ok")
' "$BATS_TEST_TMPDIR/out/.github/workflows/claude-codex-iterate.yml"
  [ "$status" -eq 99 ] && skip 'pyyaml not installed'
  assert_equal "$status" 0
  assert_contains "$output" ok
}

@test "the rendered iterate stub is unchanged apart from the verify_cmd block" {
  onboard_render node
  stub="$(rendered_stub claude-codex-iterate.yml)"
  assert_contains "$stub" 'runtime: node'
  assert_contains "$stub" 'secrets: inherit'
  refute_contains "$stub" '__RUNTIME__'
}
