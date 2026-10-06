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

@test "all three overridden: verify_cmd is those three commands, in order" {
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

# ---------- node 版本（engines 要求比 ci.yml 的默认 20 新的仓库） ----------

# package.json 写 `engines: {"node": ">=24"}` 的仓库在 node 20 上装依赖就失败，
# 而这件事只有接入那条命令说得出来 —— 覆盖值只有 install/lint/test 的话，
# 唯一的出路是接完再手改一遍生成出来的 ci.yml，没人会记得。
@test "node_version alone is not a verify command and writes no verify_cmd" {
  OV_NODE_VERSION=24 onboard_render node
  refute_contains "$(rendered_stub claude-codex-iterate.yml)" $'\n      verify_cmd:'
  assert_contains "$(rendered_stub ci.yml)" "node_version: '24'"
}

@test "no node_version override: the ci stub says nothing and keeps ci.yml's default" {
  onboard_render node
  refute_contains "$(rendered_stub ci.yml)" 'node_version:'
}

@test "the CI job's own NODE_VERSION in the environment does not leak into the rendering" {
  export NODE_VERSION='leaked-version'
  onboard_render node
  refute_contains "$(rendered_stub ci.yml)" leaked
}

# 钉住键名本身，而不只是「写出来了」。ci_overrides 是把变量名小写当键用的，
# 中央 ci.yml 哪天改了 input 名字，接入照样写得出来、workflow 当场拒收整个调用。
@test "pinned: every key ci_overrides can emit is an input ci.yml declares" {
  OV_INSTALL='make deps' OV_LINT='make lint' OV_TEST='make test' \
  OV_RUNS_ON='macos-latest' OV_NODE_VERSION=24 \
    onboard_render node
  run python3 -c '
import sys, pathlib, re
try:
    import yaml
except ImportError:
    sys.exit(99)
stub, central = (pathlib.Path(p).read_text() for p in sys.argv[1:3])
declared = set(yaml.safe_load(central)[True]["workflow_call"]["inputs"])
emitted = set(re.findall(r"^      ([a-z_]+): ", stub, re.M)) - {"runtime"}
assert emitted, "ci_overrides emitted nothing; the test is not checking anything"
missing = emitted - declared
assert not missing, f"ci.yml does not declare {sorted(missing)}"
print("ok", len(emitted))
' "$BATS_TEST_TMPDIR/out/.github/workflows/ci.yml" "$CI_WORKFLOW"
  [ "$status" -eq 99 ] && skip 'pyyaml not installed'
  assert_equal "$status" 0
  assert_contains "$output" ok
}

# 中央 iterate 的 setup-node 写死 node 20 且没有 node_version input，所以 CI 钉了
# 别的版本时两边必然不一样。接入这一刻说出来，否则只会在 Codex 第一次提意见时
# 变成一句看不懂的红。
@test "pinning CI to another node version warns that the fix round stays on 20" {
  OV_NODE_VERSION=24
  assert_contains "$(onboard_node_version_warning)" '修复那一轮固定跑 node 20'
}

@test "no node_version, or node_version 20, matches the fix round and is not warned" {
  assert_equal "$(onboard_node_version_warning)" ''
  OV_NODE_VERSION=20
  assert_equal "$(onboard_node_version_warning)" ''
}

# 上面那条警告的前提：中央 iterate 真的还是写死 20、真的还没有 node_version input。
# 哪天补上了，这条会红，提醒把警告一起删掉 —— 而不是留一句假话在接入输出里。
@test "pinned: the central iterate still hardcodes node 20 with no input to override it" {
  inputs="$(awk '/^on:/,/^jobs:/' "$ITERATE_WORKFLOW")"
  refute_contains "$inputs" 'node_version:'
  assert_contains "$(grep -A3 'setup-node' "$ITERATE_WORKFLOW")" "node-version: '20'"
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
  run bash -euo pipefail -c "$(rendered_verify_block)"
  assert_equal "$status" 0
}

# ---------- 每条命令各占一个 shell，跟 ci.yml 里各是一个 step 对齐 ----------

# ci.yml 里装 / lint / 测是三个 step，各自一个 shell；中央仓库却把整块 verify_cmd
# 当一个脚本跑。monorepo 的覆盖值三条都写 `cd frontend && ...`：不隔开的话，第一条
# 把后两条带进 frontend，它们自己的 `cd frontend` 就找不到目录 —— CI 绿、修复那一轮红。
@test "a cd in one command does not carry over into the next, as with ci.yml's separate steps" {
  OV_INSTALL='cd frontend && touch installed' \
  OV_LINT='cd frontend && test -f installed' \
  OV_TEST='cd frontend && test -f installed' \
    onboard_render node
  mkdir -p "$BATS_TEST_TMPDIR/work/frontend"
  cd "$BATS_TEST_TMPDIR/work"
  run bash -euo pipefail -c "$(rendered_verify_block)"
  assert_equal "$status" 0
}

# 反方向更糟：一条 `exit 0` 不隔开就让后面几条整个不跑，修复没验证就推上去。
# ci.yml 里它只结束自己那一步，后面的 step 照跑。
@test "an exit 0 in one command does not skip the commands after it" {
  OV_INSTALL='exit 0' OV_LINT='true' OV_TEST='false' onboard_render node
  run bash -euo pipefail -c "$(rendered_verify_block)"
  assert_equal "$status" 1
}

# ci.yml 是 eval 覆盖值的，末尾的 # 注释它照跑。括号要是跟命令写在同一行，
# 右括号就被注释吃掉、整块语法错。
@test "a trailing comment in an override does not swallow the subshell's closing paren" {
  OV_INSTALL='true # deps come from the image' OV_LINT=skip OV_TEST=skip onboard_render node
  run bash -euo pipefail -c "$(rendered_verify_block)"
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

@test "the rendered iterate stub parses as YAML with verify_cmd as three subshells" {
  OV_INSTALL='make deps' OV_LINT=skip OV_TEST='make test' onboard_render node
  run python3 -c '
import sys, pathlib
try:
    import yaml
except ImportError:
    sys.exit(99)
d = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
got = d["jobs"]["iterate"]["with"]["verify_cmd"]
want = (
    "(\n  make deps\n)\n"
    "(\n  echo \"::notice::lint skipped by caller\"\n)\n"
    "(\n  make test\n)\n"
)
assert got == want, repr(got)
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
