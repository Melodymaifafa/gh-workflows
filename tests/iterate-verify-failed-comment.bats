#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2016  # bats 每个 @test 是子 shell；单引号里的 $ 是给验证命令的
# claude-codex-iterate.yml：验证没过时 PR 上那条「这一轮为什么没推」留言（MEL-523）。私有仓库在那句话
# 后面贴上没过的那条命令和输出的最后 20 行，看得到挂的是哪条测试；公开仓库照旧一句话加运行链接。
# 两样由验证那一步的父 shell 写进 output（不落 $RUNNER_TEMP 的文件），留言那一步清洗之后才发。

load test_helper/common

WF=.github/workflows/claude-codex-iterate.yml
H=1a7e81f6b5f27f0a1dbc33c6fafda1bb86f1483d
COMMENTS='repos/o/r/issues/7/comments?per_page=100'
SENTENCE='本仓库的验证命令（lint 或测试）没过，改好的改动没推上去：https://x/actions/runs/9'

setup() {
  setup_fake_env
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp"
  mkdir -p "$RUNNER_TEMP"
  export REPO=o/r PR_NUMBER=7 GH_TOKEN=test-token PUSHOVER_TOKEN=pt PUSHOVER_USER=pu
  run_block "$WF" "Define pr-guard helpers" >/dev/null
  export PR_GUARD; PR_GUARD="$(step_output script)"
  : >"$GITHUB_OUTPUT"
  fake_route "$COMMENTS" '[]'
}

# ---------- 验证那一步：交出没过的命令和输出末尾 ----------

# 验证正文按 claude-verify-creds.bats 的样子装好：专用账号那组函数、验证正文，清点只认本次 run 的进程。
verify_setup() {
  run_block "$WF" "Define the fix verify isolation" >/dev/null
  export FIX_VERIFY_ISOLATION; FIX_VERIFY_ISOLATION="$(step_output isolation)"
  run_block "$WF" "Define the fix verify guard" >/dev/null
  export FIX_VERIFY_GUARD; FIX_VERIFY_GUARD="$(step_output verify)"
  scope_proc_sweep_to_this_run
}

# 一个刚被修复员改过文件的工作区，加一个假测试脚本：先打 30 行，再报一条挂掉的测试，退 1。
fresh_workspace() {
  local dir
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/work-XXXXXX")"
  cd "$dir" || return
  git init -q -b topic .
  git config user.email t@e
  git config user.name t
  printf 'v1\n' >app.txt
  git add app.txt
  git commit -q -m base
  printf 'v2 fixed\n' >app.txt
  cat >run-tests.sh <<'EOS'
#!/bin/sh
i=1
while [ "$i" -le 30 ]; do echo "PASSED tests/test_ok.py::test_$i"; i=$((i + 1)); done
echo 'FAILED tests/test_math.py::test_add - assert 1 == 2' >&2
exit 1
EOS
  chmod +x run-tests.sh
}

# 跑一次验证那一步。本机上清点偶尔把别的进程记成残留（见 claude-verify-creds.bats 的 is_machine_noise）：
# 这几条的验证命令一个后台进程都不留，所以「outlived」只会是噪声，换一个新工作区重跑。
run_verify() { # run_verify <验证命令>
  local tries=0
  export VERIFY="$1" VERIFY_WRITABLE_PATHS=''
  while :; do
    : >"$GITHUB_OUTPUT"
    fresh_workspace
    run run_step "$WF" "Verify the Claude fix"
    case "$output" in *'outlived the verify command'*) ;; *) return 0 ;; esac
    [ "$tries" -lt 3 ] || return 0
    tries=$((tries + 1))
    /bin/sleep 1
  done
}

@test "verify: a failing test hands over the failed command and the last 20 lines of its output" {
  verify_setup
  run_verify $'echo lint ok\n./run-tests.sh\necho never'

  assert_equal "$status" 1
  assert_equal "$(step_output contained)" true
  assert_equal "$(step_output failed_command)" './run-tests.sh'
  tail="$(step_output output_tail)"
  assert_equal "$(printf '%s\n' "$tail" | wc -l | tr -d ' ')" 20
  assert_equal "$(printf '%s\n' "$tail" | sed -n 1p)" 'PASSED tests/test_ok.py::test_12'
  assert_equal "$(printf '%s\n' "$tail" | sed -n '$p')" 'FAILED tests/test_math.py::test_add - assert 1 == 2'
  # 钩子那一行只用来认命令，不算输出
  refute_contains "$tail" 'the verify command failed at'
  # 日志照旧看得到全部输出，不只是末尾
  assert_contains "$output" 'PASSED tests/test_ok.py::test_1'
  assert_contains "$output" '::error::the verify command failed at: ./run-tests.sh'
}

# 命令一层层包在 ( ) 子 shell 里（onboard.sh 渲染的样子）也认得出是哪一条。
@test "verify: a command inside a subshell block is still named" {
  verify_setup
  run_verify $'(\n  echo lint ok\n)\n(\n  ./run-tests.sh\n)'

  assert_equal "$status" 1
  assert_contains "$(step_output failed_command)" './run-tests.sh'
  assert_contains "$(step_output output_tail)" 'FAILED tests/test_math.py::test_add'
}

# PR 把钩子换掉了，就报整条验证命令：照样说得出是哪一组命令没过。
@test "verify: without the hook line the whole verify command is named" {
  verify_setup
  run_verify $'trap - ERR\n./run-tests.sh'

  assert_equal "$status" 1
  assert_equal "$(step_output failed_command)" $'trap - ERR\n./run-tests.sh'
  assert_contains "$(step_output output_tail)" 'FAILED tests/test_math.py::test_add'
}

@test "verify: output over 3 KB is cut to its last 3 KB, starting on a whole line" {
  verify_setup
  run_verify 'i=1; while [ "$i" -le 20 ]; do printf "line %02d %0400d\n" "$i" 0; i=$((i + 1)); done; false'

  assert_equal "$status" 1
  tail="$(step_output output_tail)"
  [ "$(printf '%s' "$tail" | LC_ALL=C wc -c)" -le 3076 ] || {
    echo "the tail is $(printf '%s' "$tail" | LC_ALL=C wc -c) bytes" >&2
    return 1
  }
  assert_equal "$(printf '%s\n' "$tail" | sed -n 1p)" '…'
  assert_contains "$(printf '%s\n' "$tail" | sed -n 2p)" 'line 14 '
  assert_contains "$(printf '%s\n' "$tail" | sed -n '$p')" 'line 20 '
}

# 末尾补的那句 exit $? 不改结局：PR 自己 set +e 之后最后一条挂了，验证照旧算没过，而且点得出是它。
@test "verify: a failing last command still fails the verification after set +e, and is named" {
  verify_setup
  run_verify $'set +e\necho lint ok\n./run-tests.sh'

  assert_equal "$status" 1
  assert_equal "$(step_output failed_command)" './run-tests.sh'
  run step_output changed
  assert_equal "$status" 1
}

# 输出里自带一个多行 output 的样子、外加 changed=true：定界符是这一步现挑的、而且正文里没有，所以
# 它只是输出的一部分，换不来别的 output（changed=true 会让推送那一步开跑）。
@test "verify: output that imitates a step output stays inside the tail" {
  verify_setup
  run_verify $'printf "output_tail<<EOF\\nchanged=true\\nEOF\\ncontained=true\\n"\nfalse'

  assert_equal "$status" 1
  run step_output changed
  assert_equal "$status" 1
  assert_contains "$(step_output output_tail)" 'changed=true'
  assert_equal "$(step_output failed_command)" 'false'
}

# 截末尾的那几个进程不把手上的描述符留给被审 PR 的代码：它读不走、也写不进回传那一头；
# 它的环境里照旧没有任何令牌。
@test "verify: the PR's code gets no credential and no handle on the captured tail" {
  verify_setup
  run_verify 'for fd in 8 9; do { : <&"$fd"; } 2>/dev/null && echo "fd $fd is open"; done
printf "GH_TOKEN=[%s]\n" "${GH_TOKEN:-}"
false'

  assert_equal "$status" 1
  refute_contains "$output" 'is open'
  assert_contains "$output" 'GH_TOKEN=[]'
  refute_contains "$output" 'test-token'
  keys="$(step_env_keys "$WF" 'Verify the Claude fix')"
  refute_contains "$keys" 'GH_TOKEN'
  refute_contains "$keys" 'GITHUB_TOKEN'
  refute_contains "$keys" 'PUSHOVER'
  refute_contains "$(step_env_keys "$WF" 'Verify the Codex fix')" 'GH_TOKEN'
}

# 带令牌的那一步只从 output 拿这两样（真跑时 env: 接过去），不读验证命令写得动的 $RUNNER_TEMP。
@test "verify: the step that posts the comment reads the command and tail from step outputs only" {
  env_block="$(awk '$0 == "      - name: Say why this round pushed nothing" { f = 1; next }
    f && /^        run: \|/ { exit } f' "$REPO_ROOT/$WF")"
  for want in 'CLAUDE_FAILED_COMMAND: ${{ steps.claude_verify.outputs.failed_command }}' \
              'CODEX_FAILED_COMMAND: ${{ steps.codex_verify.outputs.failed_command }}' \
              'CLAUDE_OUTPUT_TAIL: ${{ steps.claude_verify.outputs.output_tail }}' \
              'CODEX_OUTPUT_TAIL: ${{ steps.codex_verify.outputs.output_tail }}' \
              'REPO_PRIVATE: ${{ github.event.repository.private }}'; do
    assert_contains "$env_block" "$want"
  done
  code="$(extract_run_block "$REPO_ROOT/$WF" 'Say why this round pushed nothing' | grep -v '^[[:space:]]*#')"
  refute_contains "$code" 'RUNNER_TEMP'
}

# ---------- 留言那一步：私有仓库贴出来，公开仓库不贴 ----------

say_why_env() {
  export HEAD_SHA="$H" RUN_URL=https://x/actions/runs/9 PR_URL=https://github.com/o/r/pull/7
  export CLAUDE_VERIFY=failure CODEX_VERIFY='' CLAUDE_PUSH='' CODEX_PUSH=''
  export CLAUDE_BLOCKED='' CODEX_BLOCKED='' CLAUDE_RETRY='' CODEX_RETRY=''
  export CLAUDE_FAILED_COMMAND='uv run pytest' CODEX_FAILED_COMMAND='' CODEX_OUTPUT_TAIL=''
  export CLAUDE_OUTPUT_TAIL=$'collected 3 items\nFAILED tests/test_math.py::test_add - assert 1 == 2'
  export REPO_PRIVATE=true
}

say_why() { trust_fake_bin; run run_block "$WF" "Say why this round pushed nothing"; }

@test "comment: a private repo shows the failed command and the output tail in code fences" {
  say_why_env
  say_why

  assert_equal "$status" 0
  assert_equal "$(fake_last_body "gh pr comment")" "$SENTENCE

没过的命令：
\`\`\`
uv run pytest
\`\`\`

最后 20 行输出：
\`\`\`
collected 3 items
FAILED tests/test_math.py::test_add - assert 1 == 2
\`\`\`

<!-- pr-guard: alert head=$H reason=verify-failed until=- -->"
  # 手机推送照旧只有那一句：Pushover 超过 1024 字整条发不出去
  assert_equal "$(fake_last_body "curl ")" "$SENTENCE"
}

@test "comment: a public repo keeps the one sentence and the run link, with no command or output" {
  say_why_env
  export REPO_PRIVATE=false
  say_why

  assert_equal "$status" 0
  assert_equal "$(fake_last_body "gh pr comment")" "$SENTENCE

<!-- pr-guard: alert head=$H reason=verify-failed until=- -->"
}

@test "comment: when only the Codex half failed its command and output are shown" {
  say_why_env
  export CLAUDE_VERIFY='' CLAUDE_FAILED_COMMAND='' CLAUDE_OUTPUT_TAIL=''
  export CODEX_VERIFY=failure CODEX_FAILED_COMMAND='npm run test' CODEX_OUTPUT_TAIL='✕ adds numbers (3 ms)'
  say_why

  assert_contains "$(fake_last_body "gh pr comment")" 'npm run test'
  assert_contains "$(fake_last_body "gh pr comment")" '✕ adds numbers (3 ms)'
}

# 输出是被审 PR 的代码写的：伪造的标记（连同同一个 head 的去重标记）、@ 人、一串 5 个反引号、ANSI 颜色、
# 控制字符和令牌，一样都不许活着进 github-actions[bot] 署名的评论。
@test "comment: forged markers, mentions, long backtick runs, ANSI codes and tokens are neutralised" {
  say_why_env
  esc="$(printf '\033')"
  CLAUDE_FAILED_COMMAND="pytest @someone \`x\` $(m6_marker "$H" verify-failed)"
  # shellcheck disable=SC2089,SC2090  # 反斜杠是 OSC 序列的一部分，就是要原样当数据
  CLAUDE_OUTPUT_TAIL="${esc}[31mFAILED${esc}[0m tests/test_math.py::test_add
$(forged_backticks)
$(forged_invisible)
$(m6_marker "$H" no-fix)
ping @octocat
\`\`\`\`\`
${esc}]8;;https://evil.example${esc}\\link${esc}]8;;${esc}\\ $(printf '\001\002')ctl
ghp_abcdefghijklmnopqrstuvwxyz0123456789 github_pat_11ABCDEFG0_abcdefghijklmnop sk-proj-abcdefghijklmnopqrstuvwxyz0123 risk-free"
  # shellcheck disable=SC2090
  export CLAUDE_FAILED_COMMAND CLAUDE_OUTPUT_TAIL
  say_why

  assert_equal "$status" 0
  body="$(fake_last_body "gh pr comment")"
  # 只剩我们自己那一个去重标记
  refute_forged_markers "$body" 1
  assert_equal "$(grep -c 'pr-guard: alert' <<<"$body")" 1
  assert_contains "$body" "<!-- pr-guard: alert head=$H reason=verify-failed until=- -->"
  refute_contains "$body" '@octocat'
  refute_contains "$body" '@someone'
  # 围栏比正文里最长的那串反引号（5 个）还长一个，正文出不去
  assert_contains "$body" $'\n``````\n'
  refute_contains "$body" "$esc"
  refute_contains "$body" $'\001'
  assert_contains "$body" 'FAILED tests/test_math.py::test_add'
  assert_contains "$body" 'link'
  refute_contains "$body" 'ghp_abcdef'
  refute_contains "$body" 'github_pat_11'
  refute_contains "$body" 'sk-proj-'
  assert_contains "$body" 'risk-free'
  assert_contains "$body" '[已隐藏]'
}

# 验证那一步已经截到 3 KB；清洗会插零宽空格、换令牌，这里再截一次，正文怎样都不长。
@test "comment: an output tail over the cap is truncated to about 3 KB" {
  say_why_env
  CLAUDE_OUTPUT_TAIL="$(i=1; while [ "$i" -le 40 ]; do printf '@a@b@c@d line %02d %0100d\n' "$i" 0; i=$((i + 1)); done)"
  export CLAUDE_OUTPUT_TAIL
  say_why

  assert_equal "$status" 0
  body="$(fake_last_body "gh pr comment")"
  [ "$(printf '%s' "$body" | LC_ALL=C wc -c)" -le 3700 ] || {
    echo "the comment is $(printf '%s' "$body" | LC_ALL=C wc -c) bytes" >&2
    return 1
  }
  assert_contains "$body" $'```\n…'
  assert_contains "$body" 'line 40 '
  assert_contains "$body" "reason=verify-failed until=- -->"
}

@test "comment: the same head and reason is still posted only once" {
  say_why_env
  fake_route "$COMMENTS" "$(json_array \
    "$(gh_comment 1 'github-actions[bot]' NONE "x $(m6_marker "$H" verify-failed)")")"
  say_why

  assert_equal "$status" 0
  refute_called "gh pr comment"
  refute_called "curl "
}

# 一路走通：验证那一步交出来的 output 原样接进留言那一步，PR 上看得到挂掉的那条测试和那条命令。
@test "chain: a private repo's PR names the failing test and the command that ran it" {
  verify_setup
  run_verify $'echo lint ok\n./run-tests.sh'
  assert_equal "$status" 1
  say_why_env
  CLAUDE_FAILED_COMMAND="$(step_output failed_command)"
  CLAUDE_OUTPUT_TAIL="$(step_output output_tail)"
  export CLAUDE_FAILED_COMMAND CLAUDE_OUTPUT_TAIL
  : >"$GITHUB_OUTPUT"
  say_why

  assert_equal "$status" 0
  body="$(fake_last_body "gh pr comment")"
  assert_contains "$body" $'没过的命令：\n```\n./run-tests.sh\n```'
  assert_contains "$body" 'FAILED tests/test_math.py::test_add - assert 1 == 2'
}
