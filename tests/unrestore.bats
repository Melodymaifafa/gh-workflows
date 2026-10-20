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
  # CI 上跑 bats 时这个变量是本仓库自己的名字，这里盖掉，判定才不跟着跑在哪儿变。
  export GITHUB_REPOSITORY=o/r
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
# 测试自己写索引时关掉钩子：钩子那一条种下的 post-index-change 只许被这一步触发。
swap_in_base() {
  mkdir -p .claude-pr/.claude
  cp CLAUDE.md .claude-pr/CLAUDE.md
  cp .claude/settings.json .claude-pr/.claude/settings.json
  echo '/.claude-pr/' >>.git/info/exclude
  printf 'base-version\n' >CLAUDE.md
  printf '{"base":true}\n' >.claude/settings.json
  printf '{"base_only":true}\n' >.claude/base-only.json
  git -c core.hooksPath=/dev/null add CLAUDE.md
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

# HEAD 里那个路径是子模块：actions/checkout 默认不拉子模块，它那个提交对象不在本仓库里，
# 可它照样是「HEAD 有」。当成「HEAD 没有」去删，后面的 add -A 就推一笔删掉 PR 子模块的提交。
@test "unrestore: a submodule the PR has at one of these paths is kept, not deleted" {
  printf '[submodule ".claude"]\n\tpath = .claude\n\turl = https://example.invalid/sub.git\n' >.gitmodules
  sub="$(printf 'not-in-this-repo' | git hash-object --stdin)"
  git add .gitmodules
  git update-index --add --cacheinfo "160000,$sub,.claude"
  git commit -q -m pr

  # 照 action 的样子换进 base 版：base 的 .claude/ 是个普通目录。第一遍 base 的
  # .gitmodules 跟 PR 一样（删子模块那一下会悄悄进索引），第二遍也不一样（git rm 会
  # 当场报错、整轮红掉）。
  for base_gitmodules in same different; do
    mkdir -p .claude
    printf '{"base":true}\n' >.claude/settings.json
    [ "$base_gitmodules" = same ] || printf '# base\n' >.gitmodules

    run_block "$WF" "$STEP"

    assert_equal "$(git ls-files -s .claude)" "160000 $sub 0"$'\t'".claude"
    assert_equal "$(ls -A .claude)" ''
    assert_equal "$(cat .gitmodules)" "$(git show HEAD:.gitmodules)"
    assert_equal "$(git status --porcelain --untracked-files=all --ignored)" ''
  done
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

# 按路径 restore 会触发 post-checkout，restore 和 rm --cached 写索引都会触发
# post-index-change。仓库里种下的钩子（.git/hooks 里的，或者 .git/config 里
# core.hooksPath 指过去的）都不许借这一步跑起来。
@test "unrestore: a hook planted in the checkout never runs" {
  pr_commit
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere-hooks"
  for dir in .git/hooks "$BATS_TEST_TMPDIR/elsewhere-hooks"; do
    for hook in post-checkout post-index-change; do
      printf '#!/bin/sh\necho %s >>"%s/hook-ran"\n' "$hook" "$BATS_TEST_TMPDIR" >"$dir/$hook"
      chmod +x "$dir/$hook"
    done
  done

  for round in hooks-dir hooks-path; do
    [ "$round" = hooks-dir ] || git config core.hooksPath "$BATS_TEST_TMPDIR/elsewhere-hooks"
    swap_in_base
    # HEAD 没有的 .mcp.json 也留一份在暂存区：rm --cached 那一行也得写一次索引
    printf '{"mcpServers":{}}\n' >.mcp.json
    git -c core.hooksPath=/dev/null add .mcp.json

    run_block "$WF" "$STEP"

    assert_equal "$(cat CLAUDE.md)" 'pr-version'
    assert_equal "$(git ls-files -- .mcp.json)" ''
  done
  assert_equal "$(cat "$BATS_TEST_TMPDIR/hook-ran" 2>/dev/null)" ''
}

# action 在 agent 模式下把手上的令牌写进 origin 的地址（v1.0.241 的
# src/github/operations/git-config.ts），跑完不收回；修复员传的是 job 自己的令牌，整个 job
# 都有效。验证那一步跑被审 PR 自己的命令，读个文件就拿走了。这一步把它抹掉。
@test "unrestore: the token the action wrote into a remote's URL is gone before verify" {
  pr_commit
  git remote add origin 'https://x-access-token:abc@github.com/o/r.git'
  git remote add upstream 'https://user:pw@example.com/up.git'
  git remote add mirror "$BATS_TEST_TMPDIR/mirror.git"

  run_block "$WF" "$STEP"

  assert_equal "$(git config --local --get remote.origin.url)" 'https://github.com/o/r.git'
  assert_equal "$(git config --local --get remote.upstream.url)" 'https://example.com/up.git'
  # 不带凭据的地址原样留着：真跑那条链的测试里 origin 就是一个本地裸仓库
  assert_equal "$(git config --local --get remote.mirror.url)" "$BATS_TEST_TMPDIR/mirror.git"
  refute_contains "$(cat .git/config)" 'abc'
  refute_contains "$(cat .git/config)" 'pw@'
}

# actions/checkout 的 extraheader（本 job 关了持久化，这里仍然种一份）、任何一种 credential
# 配置（helper 是「! 开头就是 shell」的那种，也可能直接吐出密码）都不许留到验证。
@test "unrestore: an extraheader and a credential helper in .git/config are removed" {
  pr_commit
  git config --local http.https://github.com/.extraheader 'AUTHORIZATION: basic c2VjcmV0'
  git config --local --add http.https://github.com/.extraheader 'AUTHORIZATION: basic second'
  git config --local http.extraheader 'AUTHORIZATION: bearer third'
  git config --local credential.helper '!f() { echo password=secret; }; f'
  git config --local credential.https://github.com.username x-access-token

  run_block "$WF" "$STEP"

  cfg="$(git config --local --list)"
  refute_contains "$cfg" 'extraheader'
  refute_contains "$cfg" 'credential.'
  refute_contains "$cfg" 'secret'
  refute_contains "$cfg" 'c2VjcmV0'
  # 别的配置照旧
  assert_equal "$(git config --local --get user.name)" t
}

# 抹不掉就不许往下走：宁可这一轮红，也不让验证命令带着一份凭据开跑。报的是键名，不是值。
@test "unrestore: a credential the step cannot remove turns the step red" {
  pr_commit
  git remote add origin 'https://x-access-token:abc@github.com/o/r.git'
  git config --local http.https://github.com/.extraheader 'AUTHORIZATION: basic c2VjcmV0'
  # 一个改不动配置的 git：写配置的那几下都失败，别的照常
  real_git="$(command -v git)"
  mkdir -p "$BATS_TEST_TMPDIR/stuck-git"
  printf '#!/bin/sh\ncase " $* " in\n  *" set-url "*|*" --unset-all "*) echo "error: could not lock config file" >&2; exit 255 ;;\nesac\nexec "%s" "$@"\n' \
    "$real_git" >"$BATS_TEST_TMPDIR/stuck-git/git"
  chmod +x "$BATS_TEST_TMPDIR/stuck-git/git"

  PATH="$BATS_TEST_TMPDIR/stuck-git:$PATH" run run_block "$WF" "$STEP"

  assert_equal "$status" 1
  assert_contains "$output" '::error::'
  assert_contains "$output" 'remote.origin.url'
  assert_contains "$output" 'http.https://github.com/.extraheader'
  refute_contains "$output" 'abc'
  refute_contains "$output" 'c2VjcmV0'
}

# 凭据也可能在 .git/config 用 include.path 引进来的另一个文件里（actions/checkout v4.3.1 起
# 持久化就写在那儿）。这一步只改 .git/config 自己，所以那一份抹不掉 —— 照样红。
@test "unrestore: a credential pulled in through include.path also turns the step red" {
  pr_commit
  printf '[http "https://github.com/"]\n\textraheader = AUTHORIZATION: basic c2VjcmV0\n' \
    >"$BATS_TEST_TMPDIR/included.cfg"
  git config --local include.path "$BATS_TEST_TMPDIR/included.cfg"

  run run_block "$WF" "$STEP"

  assert_equal "$status" 1
  assert_contains "$output" '::error::'
  assert_contains "$output" 'http.https://github.com/.extraheader'
}

# 它放在验证前紧挨着的那一步：排在它后面的 Claude 步骤会再换一次 base 版。它不碰凭据：
# 只动工作区、索引和 .git/config。
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
