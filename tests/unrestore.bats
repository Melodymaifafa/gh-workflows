#!/usr/bin/env bats
# claude-codex-iterate.yml 的 Put back the PR's own config files 那一步。
# claude-code-action 在 PR 类事件上开跑前，把 PR 里的 CLAUDE.md、.claude/、.husky 这几样
# 换成 base 分支的版本（PR 的原样快照进 .claude-pr/），跑完不换回来
# （src/github/operations/restore-config.ts，v1.0.241）。验证那一步 add -A 入暂存区，于是
# 改过这些文件的 PR 修一轮就被悄悄撤销了。守的是：修复员跑过之后、验证之前，工作区和
# 索引里这几个路径都回到 HEAD 的样子，修复员别处的改动原样留着。

load test_helper/common
load test_helper/step_gate

WF=.github/workflows/claude-codex-iterate.yml
STEP="Put back the PR's own config files"
CLAUDE_FIXER_STEP='uses: anthropics/claude-code-action@cab360f6565aa35a51d6ce9e43f1f4287c0a32ea # v1.0.241'

setup() {
  setup_fake_env
  mkdir -p "$BATS_TEST_TMPDIR/work"
  cd "$BATS_TEST_TMPDIR/work" || return
  git init -q -b topic .
  git config user.email t@e
  git config user.name t
}

# 被审 PR 的 HEAD：它自己的 CLAUDE.md 和 .claude/settings.json，外加一个普通源文件。
pr_commit() {
  mkdir -p .claude src
  printf 'pr-version\n' >CLAUDE.md
  printf '{"pr":true}\n' >.claude/settings.json
  printf 'echo a\n' >src/a.sh
  git add -A
  git commit -q -m pr
}

# 照 action 的样子换进 base 版：PR 的原样快照进 .claude-pr/（action 把它写进
# .git/info/exclude），再换上 base 的内容，外加一个只有 base 才有的文件。action 自己会
# git reset 取消暂存；这里故意留一份在暂存区，看这一步连索引一起放回去。
swap_in_base() {
  mkdir -p .claude-pr/.claude
  cp CLAUDE.md .claude-pr/CLAUDE.md
  cp .claude/settings.json .claude-pr/.claude/settings.json
  echo '/.claude-pr/' >>.git/info/exclude
  printf 'base-version\n' >CLAUDE.md
  printf '{"base":true}\n' >.claude/settings.json
  printf '{"base_only":true}\n' >.claude/base-only.json
  git add CLAUDE.md
}

# 按出现顺序列出 workflow 里每一步的名字；`- uses:` 开头的记成「uses: 后面那一串」，
# 跟门禁模型的叫法一样。
step_names() {
  awk '
    /^      - name: / { print substr($0, 15); next }
    /^      - uses: / { print "uses: " substr($0, 15) }
  ' "$REPO_ROOT/$WF"
}

# 这一步自己的全文：从 `- name:` 那行到下一步之前。
step_text() {
  awk -v want="      - name: $STEP" '
    $0 == want             { f = 1; print; next }
    f && /^      - /       { exit }
    f && /^      # /       { exit }
    f
  ' "$REPO_ROOT/$WF"
}

@test "unrestore: a PR's own CLAUDE.md and .claude/ come back after the fixer" {
  pr_commit
  swap_in_base

  run_block "$WF" "$STEP"

  assert_equal "$(cat CLAUDE.md)" 'pr-version'
  assert_equal "$(cat .claude/settings.json)" '{"pr":true}'
  # base 才有的文件也得走：目录里只剩 HEAD 有的那些
  assert_equal "$(ls -A .claude)" 'settings.json'
  assert_equal "$(ls -A | grep -cxF .claude-pr)" 0
  # 工作区和索引都等于 HEAD：没有改动、没有未跟踪的、也没有被忽略的残留（.claude-pr/
  # 在 exclude 里，留着的话只有 --ignored 看得见它）
  assert_equal "$(git status --porcelain --untracked-files=all --ignored)" ''
}

@test "unrestore: a path the PR does not have is removed" {
  pr_commit
  # base 有、PR 没有的 .husky/ 和 .mcp.json；后者故意留在暂存区
  mkdir -p .husky
  printf 'npm test\n' >.husky/pre-commit
  printf '{"mcpServers":{}}\n' >.mcp.json
  git add .mcp.json

  run_block "$WF" "$STEP"

  assert_equal "$(ls -A | grep -cxE '\.husky|\.mcp\.json')" 0
  assert_equal "$(git ls-files -- .husky .mcp.json)" ''
  assert_equal "$(git status --porcelain --untracked-files=all --ignored)" ''
}

@test "unrestore: the fixer's own edits outside these paths stay" {
  pr_commit
  swap_in_base
  # 修复员这一轮改出来的东西：改一个文件、加一个文件
  printf 'echo fixed\n' >src/a.sh
  printf 'echo new\n' >src/b.sh

  run_block "$WF" "$STEP"

  assert_equal "$(cat src/a.sh)" 'echo fixed'
  assert_equal "$(cat src/b.sh)" 'echo new'
  # 验证那一步照样 add -A：入暂存区的只有修复员的改动，换进来的 base 版一个都不在
  git add -A
  assert_equal "$(git diff --cached --name-only)" $'src/a.sh\nsrc/b.sh'
}

# 按路径 restore 也会触发 post-checkout。仓库里种下的钩子（.git/hooks 里的，或者
# .git/config 里 core.hooksPath 指过去的）都不许借这一步跑起来。
@test "unrestore: a hook planted in the checkout never runs" {
  pr_commit
  swap_in_base
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere-hooks"
  for dir in .git/hooks "$BATS_TEST_TMPDIR/elsewhere-hooks"; do
    printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$BATS_TEST_TMPDIR" >"$dir/post-checkout"
    chmod +x "$dir/post-checkout"
  done

  run_block "$WF" "$STEP"
  git config core.hooksPath "$BATS_TEST_TMPDIR/elsewhere-hooks"
  swap_in_base
  run_block "$WF" "$STEP"

  assert_equal "$(cat CLAUDE.md)" 'pr-version'
  assert_equal "$(ls -A "$BATS_TEST_TMPDIR" | grep -cxF hook-ran)" 0
}

# 它放在验证前紧挨着的那一步：排在它后面的 Claude 步骤会再换一次 base 版。它不碰凭据：
# 只动工作区和索引。
@test "unrestore: the step runs right before the first verify step and holds no credentials" {
  before_verify="$(step_names | awk '$0 == "Verify the Claude fix" { print prev; exit } { prev = $0 }')"
  assert_equal "$before_verify" "$STEP"
  # 也在修复员之后（中间以后还会插自审、第二遍）
  fixer_at="$(step_names | grep -nxF "$CLAUDE_FIXER_STEP" | cut -d: -f1)"
  step_at="$(step_names | grep -nxF "$STEP" | cut -d: -f1)"
  [ -n "$fixer_at" ] || { echo 'the Claude fixer step was not found' >&2; return 1; }
  assert_equal "$((step_at > fixer_at))" 1

  text="$(step_text)"
  assert_contains "$text" '        run: |'
  refute_contains "$(step_env_keys "$WF" "$STEP")" 'TOKEN'
  refute_contains "$text" 'secrets.'
  refute_contains "$text" 'github.token'
  refute_contains "$text" 'TOKEN'
}

# 修复员 continue-on-error：撞额度失败时 outcome 是 failure，换进来的 base 版照样留在
# 工作区，Decide the takeover 看工作区不干净就不许 Codex 接手。所以成功、失败都要跑。
@test "unrestore: the step runs whenever the Claude fixer ran, success or failure" {
  assert_equal "$(step_key "$WF" "$STEP" if)" \
    "steps.gate.outputs.run == 'true' && steps.select.outputs.first == 'claude' && (steps.fix.outcome == 'success' || steps.fix.outcome == 'failure')"

  claude_round() {
    gate_reset
    gate_set inputs.runtime shell
    gate_set inputs.review_fixer auto
    gate_set steps.gate.outputs.run true
    gate_set steps.select.outputs.first claude
    gate_set steps.select.outcome success
  }

  claude_round
  gate_trace "$WF"
  gate_ran "$STEP"
  gate_ran 'Verify the Claude fix'

  # 撞额度：放回这一步照跑，后面的换人裁决照跑
  claude_round
  gate_fails "$CLAUDE_FIXER_STEP"
  gate_trace "$WF"
  gate_ran "$STEP"
  gate_skipped 'Verify the Claude fix'
  gate_ran 'Decide the takeover'

  # Claude 没上：修复员没跑，什么都没换进来
  gate_reset
  gate_set inputs.runtime shell
  gate_set inputs.review_fixer codex
  gate_set steps.gate.outputs.run true
  gate_set steps.select.outputs.first codex
  gate_set steps.select.outcome success
  gate_trace "$WF"
  gate_skipped "$CLAUDE_FIXER_STEP"
  gate_skipped "$STEP"

  gate_reset
  gate_set inputs.runtime shell
  gate_set steps.gate.outputs.run false
  gate_trace "$WF"
  gate_skipped "$STEP"
}

# 门禁模型要算得出上面那个带括号的条件，而不是把它当成「&& 和 || 混用」报看不懂。
@test "unrestore: the gate model evaluates a parenthesised || group inside an && chain" {
  gate_reset
  gate_set steps.a.outputs.x yes
  expr="steps.a.outputs.x == 'yes' && (steps.fix.outcome == 'success' || steps.fix.outcome == 'failure')"

  gate_set steps.fix.outcome failure
  if gate_eval "$expr"; then rc=0; else rc=$?; fi
  assert_equal "$rc" 0

  gate_set steps.fix.outcome skipped
  if gate_eval "$expr"; then rc=0; else rc=$?; fi
  assert_equal "$rc" 1

  # 不带括号的混用照旧判看不懂
  if gate_eval "steps.a.outputs.x == 'yes' && steps.fix.outcome == 'success' || steps.fix.outcome == 'failure'"; then rc=0; else rc=$?; fi
  assert_equal "$rc" 2
}

# 路径清单抄自 action 源码，跟修复员钉的版本走：升级 action 而不回头对一遍清单，
# 新版多换进来的路径就又被悄悄提交回去。
@test "unrestore: the path list is the one of the action version the fixer is pinned to" {
  block="$(extract_run_block "$REPO_ROOT/$WF" "$STEP")"
  assert_contains "$block" 'paths=(.claude .mcp.json .claude.json .gitmodules .ripgreprc CLAUDE.md CLAUDE.local.md .husky)'
  pinned="$(awk '
    /^      - uses: anthropics\/claude-code-action@/ { v = $0; sub(/^.* # /, "", v); next }
    v != "" && $0 == "        id: fix" { print v; exit }
    { v = "" }
  ' "$REPO_ROOT/$WF")"
  assert_equal "$pinned" 'v1.0.241'
  assert_contains "$block" "claude-code-action $pinned"
  assert_contains "$block" 'src/github/operations/restore-config.ts'
}
