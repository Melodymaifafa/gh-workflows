#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats 每个 @test 是子 shell
# claude-codex-iterate.yml 的 Claude 那条路：被审 PR 自己带的验证命令，跟写权限凭据
# 不许出现在同一步里（MEL-254）。守三件事：
#   1. 跑 Claude 的那一步不给它任何「会执行仓库里代码」的工具，也不让它自己 push ——
#      那一步必须有令牌（action 自己要用），所以只能让 PR 的代码进不来。
#   2. 跑验证的那一步手上什么凭据都没有：没有令牌，也没有 checkout 留在 .git/config
#      里那份。
#   3. 验证动过 .git、改过不许它改的文件、或留下活进程，就红着停下，绝不 commit / push。
# Codex 那条路的同名判定在 codex-takeover.bats；两份防线是逐行副本，改一份必须改另一份。

load test_helper/common
load test_helper/step_gate

WF=.github/workflows/claude-codex-iterate.yml

setup() {
  setup_fake_env
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp"
  mkdir -p "$RUNNER_TEMP" "$BATS_TEST_TMPDIR/work"
  cd "$BATS_TEST_TMPDIR/work" || return
  # 噪声重跑时要用的 git：在测试往 PATH 上种任何东西之前先认下来
  REAL_GIT="$(command -v git)"
  export REAL_GIT
}

# ---------- 结构：Claude 那一步拿到的工具和提示词 ----------

claude_step_block() {
  awk '/^      - uses: anthropics\/claude-code-action@v1/{f=1} f&&/^      - name:/{exit} f' \
    "$REPO_ROOT/$WF"
}

claude_prompt() {
  awk '/^          prompt: \|/{f=1} f&&/^      - name:/{exit} f' "$REPO_ROOT/$WF"
}

# 这一步跟令牌同一个进程，所以清单里不许有任何「会跑仓库里的代码」的东西：
# 工具链（npm / uv / bats…）执行的是被审 PR 自己带的脚本，拿到它就等于拿到令牌。
@test "claude: the fixer step is given no tool that can execute the PR's own code" {
  tools="$(claude_step_block | sed -nE 's/^ *--allowedTools "(.*)"$/\1/p')"
  [ -n "$tools" ] || { echo 'no --allowedTools found on the Claude step' >&2; return 1; }

  # runtime 工具链：整条 EXTRA_TOOLS 都不许再拼进来
  refute_contains "$tools" 'EXTRA_TOOLS'
  for t in 'Bash(uv:' 'Bash(uvx:' 'Bash(npm:' 'Bash(npx:' 'Bash(node:' \
           'Bash(bats:' 'Bash(actionlint:' 'Bash(shellcheck:' 'Bash(xargs'; do
    refute_contains "$tools" "$t"
  done
  # 宽泛的 git / bash 通道同样不许
  refute_contains "$tools" 'Bash(git:*)'
  refute_contains "$tools" 'Bash(bash'
  refute_contains "$tools" 'Bash(sh'

  # 还得真能改文件，否则这一步白跑、这条断言也就空转
  assert_contains "$tools" 'Edit,MultiEdit,Write'
}

# 写权限动作全部挪出这一步：它自己 push / 发评论就意味着验证命令跟凭据同处一步。
@test "claude: the fixer step can no longer write to the repo or the PR by itself" {
  tools="$(claude_step_block | sed -nE 's/^ *--allowedTools "(.*)"$/\1/p')"
  for t in 'Bash(git push' 'Bash(git commit' 'Bash(git add' 'Bash(git fetch' \
           'Bash(git pull' 'Bash(gh pr comment'; do
    refute_contains "$tools" "$t"
  done
}

# 验证命令只能出现在不带凭据的那一步的 env: 里，不能再写进提示词让 Claude 自己跑。
@test "claude: the verify commands are no longer handed to the fixer prompt" {
  prompt="$(claude_prompt)"
  [ -n "$prompt" ] || { echo 'no prompt found on the Claude step' >&2; return 1; }
  refute_contains "$prompt" 'env.VERIFY_CMD'
  assert_contains "$(step_env_keys "$WF" 'Verify the Claude fix')" 'VERIFY'
}

# checkout 那份凭据是「读一个文件就换来仓库写权限」的东西，而这个工作区里要跑被审
# PR 自己带的命令。本 job 没有一步依赖它：两条路的 push 都自己现造一份。
@test "claude: the checkout leaves no write credential in .git/config" {
  assert_contains "$(cat "$REPO_ROOT/$WF")" 'persist-credentials: false'
}

# 令牌只在子进程里用 env -u 抹掉是不够的：父 shell 那份环境还在，验证命令跟它同一个
# 用户，/proc/$PPID/environ 原样读得回来。要守的是「跑验证那一步自己的 env: 里根本
# 没有令牌」—— 把令牌挪回去，这一条就红。
@test "claude: the step that runs the PR's verify command declares no token at all" {
  keys="$(step_env_keys "$WF" 'Verify the Claude fix')"
  refute_contains "$keys" 'GH_TOKEN'
  refute_contains "$keys" 'GITHUB_TOKEN'
  # 跑验证的确实是这一步，否则改个步骤名这条就空转
  assert_contains "$(extract_run_block "$REPO_ROOT/$WF" 'Verify the Claude fix')" \
    'bash -euo pipefail -c "$VERIFY"'
  # 带令牌的那一步反过来不许碰验证命令
  assert_contains "$(step_env_keys "$WF" 'Commit and push the Claude fix')" 'GH_TOKEN'
  refute_contains "$(extract_run_block "$REPO_ROOT/$WF" 'Commit and push the Claude fix')" 'VERIFY'
}

# ---------- 真跑一遍：验证、提交、推送 ----------

# 验证那一步和随后 commit/push 那一步共用的工作区：一个带 origin 的真仓库，加上 Claude
# 刚改过的文件。VERIFY 是被审 PR 自己带的命令，这里换成探针，用来看它看得见什么。
# 凭据照 actions/checkout 的老样子写进 .git/config：workflow 里已经关掉持久化了，这里
# 仍然种一份 —— 万一那一行被改回去，下面的判定得照样把它摘掉。
push_workspace() { # push_workspace <verify script>
  git init -q -b topic .
  git config user.email t@e
  git config user.name t
  printf 'v1\n' >app.txt
  printf 'lock v1\n' >deps.lock
  git add app.txt deps.lock
  git commit -q -m base
  git init -q --bare "$BATS_TEST_TMPDIR/origin.git"
  git remote add origin "$BATS_TEST_TMPDIR/origin.git"
  git push -q origin HEAD:topic
  git config --local http.https://github.com/.extraheader 'AUTHORIZATION: basic c2VjcmV0'
  mkdir -p .git/info .review
  echo '.review/' >>.git/info/exclude
  printf 'prefetched review\n' >.review/findings.md
  printf 'v2 fixed by claude\n' >app.txt
  export VERIFY="$1"
  # 调用方没写白名单 = 一个被跟踪的文件都不许验证命令改写（失败关闭）。
  export VERIFY_WRITABLE_PATHS="${VERIFY_WRITABLE_PATHS:-}"
  export HEAD_REF=topic PR_NUMBER=7 GH_TOKEN=write-token
}

verify_and_push() {
  run_step "$WF" "Verify the Claude fix" &&
    run_step "$WF" "Commit and push the Claude fix"
}

# 「验证留下的活进程」那一道按**运行用户**清点残留 —— 这是它挡得住 setsid 的原因，
# 也意味着本机跑测试时，机器上任何一个恰好在这一瞬起来、又活过 5 秒容忍窗口的进程
# 同样会被记一笔。runner 上进程表干净，生产路径不会撞上；本机会。
# 判据是「报出来的那个 pid 是不是我们种的那个」：是 = 防线抓到了探针，绝不重跑。
is_machine_noise() {
  local f pid
  case "$output" in *'outlived the verify command'*) ;; *) return 1 ;; esac
  for f in escaped.pid leftover.pid; do
    pid="$(cat "$BATS_TEST_TMPDIR/$f" 2>/dev/null || true)"
    [ -n "$pid" ] || continue
    case "$output" in *"$pid ("*) return 1 ;; esac
  done
  return 0
}

# 重跑之前工作区必须退回 push_workspace 刚布好的样子：上一次尝试里验证命令已经把
# 载荷写进工作区、还可能自己 git add 过了，不退回去，第二次的「验证前」就已经带着
# 载荷，前后一比没差异，夹带的文件反倒顺利推出去。
# git 走绝对路径：有的测试往 PATH 上种了假 git，退工作区不该去跑它。
reset_workspace() {
  "$REAL_GIT" reset -q --hard origin/topic
  "$REAL_GIT" clean -qfdx
  printf 'v2 fixed by claude\n' >app.txt
  mkdir -p .review
  printf 'prefetched review\n' >.review/findings.md
}

run_verify() {
  local tries=0
  run run_step "$WF" "Verify the Claude fix"
  while [ "$tries" -lt 3 ] && is_machine_noise; do
    tries=$((tries + 1))
    /bin/sleep 1
    reset_workspace
    run run_step "$WF" "Verify the Claude fix"
  done
}

run_chain() {
  local tries=0
  run verify_and_push
  while [ "$tries" -lt 3 ] && is_machine_noise; do
    tries=$((tries + 1))
    /bin/sleep 1
    reset_workspace
    run verify_and_push
  done
}

# 这是本票的核心判定：验证命令来自被审的那个 PR（npm ci 的生命周期钩子、pytest 插件、
# tests/*.bats 里的任意一行都能执行代码）。它跑的时候，环境里不能有 contents:write
# 的令牌，.git/config 里也不能有 checkout 留下的凭据 —— 拿到任何一样就等于拿到仓库
# 写权限。把验证挪回 Claude 那一步，这一条就红。
@test "claude: the PR's own verify command runs without any write credential" {
  push_workspace 'probe="$BATS_TEST_TMPDIR/probe.txt"
printf "GH_TOKEN=[%s]\n" "${GH_TOKEN:-}" >"$probe"
printf "GITHUB_TOKEN=[%s]\n" "${GITHUB_TOKEN:-}" >>"$probe"
git config --local --get http.https://github.com/.extraheader >>"$probe" ||
  echo "git-credential=[]" >>"$probe"'

  run_verify

  assert_equal "$status" 0
  probe="$(cat "$BATS_TEST_TMPDIR/probe.txt")"
  assert_contains "$probe" 'GH_TOKEN=[]'
  assert_contains "$probe" 'GITHUB_TOKEN=[]'
  assert_contains "$probe" 'git-credential=[]'
  # 摘掉之后不再还回去：凭据整个收进下一步内部，两步之间 .git/config 里一个字都没有，
  # 逃过收尾的进程盯着这个文件也等不到东西（MEL-255）。
  assert_equal "$(git config --local --get http.https://github.com/.extraheader || echo none)" 'none'
  assert_equal "$(step_output changed)" true
}

# 上一条只看子进程自己那份环境，看不出令牌是不是还挂在父 shell 上。这一条把父进程的
# 环境整个读出来。只有 /proc 在的平台能读（CI 的 ubuntu-latest 就是）。
@test "claude: the verification's parent shell holds no write credential either" {
  [ -r /proc/self/environ ] || skip 'no /proc here; the env:-declaration test covers this platform'
  push_workspace 'tr "\0" "\n" <"/proc/$PPID/environ" >"$BATS_TEST_TMPDIR/parent-env.txt"'

  run_verify

  assert_equal "$status" 0
  parent="$(cat "$BATS_TEST_TMPDIR/parent-env.txt")"
  # 探针真读到那份环境了，否则下面那条 refute 只是在空字符串上空转
  assert_contains "$parent" 'HEAD_REF=topic'
  refute_contains "$parent" 'GH_TOKEN='
  refute_contains "$parent" 'write-token'
}

# 验证红了就什么都不推：推出去的必须是验过的那棵树。
@test "claude: a failing verification pushes nothing" {
  push_workspace 'exit 1'

  run_chain

  [ "$status" -ne 0 ]
  assert_contains "$output" 'verification failed after the Claude fix'
  assert_equal "$(git rev-parse origin/topic)" "$(git rev-parse HEAD)"
  refute_called 'gh pr comment'
}

# 验证命令往 .git 里种一个「后面某一步会去跑」的钩子 —— 下一步手上有写权限凭据，
# 种下去就有人替它跑。验证前后指纹有差异就红着停下，停在凭据回来之前。
@test "claude: a hook the verify command plants stops the chain before the credentials return" {
  push_workspace 'printf "#!/bin/sh\ntouch \"$BATS_TEST_TMPDIR/hook-ran\"\n" >.git/hooks/post-index-change
chmod +x .git/hooks/post-index-change'

  run_chain

  [ "$status" -ne 0 ]
  assert_contains "$output" 'the verify command modified .git'
  [ ! -e "$BATS_TEST_TMPDIR/hook-ran" ]
  assert_equal "$(git rev-parse origin/topic)" "$(git rev-parse HEAD)"
}

# 验证命令借那次 add -u 把自己改的源文件夹带进提交里 —— 外部 PR 于是能借这条工作流
# 的手，把复审机器人从没产出过的改动发布进仓库。白名单之外的一条都不许过。
@test "claude: a source file the verify command rewrote off the allowlist never gets pushed" {
  push_workspace 'printf "smuggled\n" >app.txt'

  run_chain

  [ "$status" -ne 0 ]
  assert_contains "$output" 'rewrote tracked files outside verify_writable_paths'
  assert_equal "$(git rev-parse origin/topic)" "$(git rev-parse HEAD)"
}

# 反面：调用方放行的锁文件（uv.lock / package-lock.json 这类）照旧要能跟着推出去，
# 否则推的就是一棵从没被验证过的树。
@test "claude: a lock file the caller put on the allowlist still ships" {
  export VERIFY_WRITABLE_PATHS=deps.lock
  push_workspace 'printf "lock v2\n" >deps.lock'

  run_chain

  assert_equal "$status" 0
  refute_contains "$output" 'outside verify_writable_paths'
  assert_equal "$(git show origin/topic:deps.lock)" 'lock v2'
  assert_equal "$(git show origin/topic:app.txt)" 'v2 fixed by claude'
}

# 验证留下一个活进程，它盯着 .git/config 等凭据回来。两道各守一半：跑完先按进程组
# 收掉它，而且凭据摘掉之后再也不还回那个文件 —— 战利品是空的 = 它什么都没等到。
@test "claude: a process the verify command leaves behind never sees the credentials return" {
  push_workspace "cfg=\"\$PWD/.git/config\"
loot=$BATS_TEST_TMPDIR/payload-loot.txt
( i=0
  while [ \"\$i\" -lt 20000 ]; do
    if grep -q extraheader \"\$cfg\" 2>/dev/null; then cp \"\$cfg\" \"\$loot\"; exit 0; fi
    i=\$((i + 1))
  done ) >/dev/null 2>&1 &
echo \"\$!\" >$BATS_TEST_TMPDIR/leftover.pid
"

  run_chain

  assert_equal "$status" 0
  assert_equal "$(cat "$BATS_TEST_TMPDIR/payload-loot.txt" 2>/dev/null || true)" ''
  pid="$(cat "$BATS_TEST_TMPDIR/leftover.pid")"
  if kill -0 "$pid" 2>/dev/null; then echo "leftover $pid is still alive" >&2; return 1; fi
  # 这一道不能靠「整条链红了」通过
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse origin/topic)"
}

# ---------- 总结评论 ----------

# 总结由外层步骤发，文本走结构化输出：Claude 自己发就得在跑验证的同一步里握着令牌。
# 正文断言读 run summary 里那一份：这一步的 gh 只从「被审 PR 写不动的目录」里找（见
# 下面那条种假 gh 的判定），测试里那个假 gh 放在仓库目录下、过滤之后拦不到它了 ——
# 而正文发不出去也会落进 run summary，所以判的还是同一段文本。
@test "claude: the summary comment body comes from the structured output" {
  export STRUCTURED='{"pushed":true,"fixed":2,"skipped":1,"summary":"修了 2 条，跳过 1 条"}'
  export PUSHED=true REPO=o/r PR_NUMBER=7 GH_TOKEN=t
  # 真 gh 在写保护目录里的机器（runner 就是）上，这一步会真去发一条评论：指到本机
  # 回环地址上，连接直接被拒，不出网也不碰真 API。
  export GH_HOST=127.0.0.1

  run run_step "$WF" "Post the Claude summary comment"

  assert_equal "$status" 0
  body="$(cat "$GITHUB_STEP_SUMMARY")"
  assert_contains "$body" '修了 2 条，跳过 1 条'
  assert_contains "$body" '不带写权限的独立步骤里跑过'
}

# 模型漏了 summary 只是少一条评论，不许把整轮判红 —— 代码已经验过、推过了。
@test "claude: a missing summary only warns; it never reds the round" {
  export STRUCTURED='{"pushed":false,"fixed":0,"skipped":3}'
  export PUSHED='' REPO=o/r PR_NUMBER=7 GH_TOKEN=t

  run run_step "$WF" "Post the Claude summary comment"

  assert_equal "$status" 0
  assert_contains "$output" 'returned no summary'
  refute_called 'gh pr comment'
  assert_equal "$(cat "$GITHUB_STEP_SUMMARY")" ''
}

# 本票第 2 轮堵的那个洞：这一步手上有写权限令牌，而它前面那一步跑的是被审 PR 自己的
# 命令 —— PR 往「自己写得动的 PATH 目录」放一个假 gh（顺手再放个假 jq），这一步去跑
# 它就等于把令牌连同正文一起递过去。验证那一步的三道门都看不见：文件在仓库外、没动
# .git、放的是文件不是进程。所以它跟「提交并推送」那一步同一个规矩：命令只从我们写
# 不动的目录里找。把那段过滤摘掉，这一条当场变红（假 gh 的日志里就有令牌）。
@test "claude: a gh planted on a writable PATH entry never gets the comment token" {
  # 模拟 runner 的 PATH：第一项是验证命令（也就是被审 PR）写得动的目录
  plant_fake_tools "$BATS_TEST_TMPDIR/plantable-bin" gh jq
  export STRUCTURED='{"pushed":true,"summary":"修了 2 条，跳过 1 条"}'
  export PUSHED=true REPO=o/r PR_NUMBER=7 GH_TOKEN=write-token GH_HOST=127.0.0.1

  run run_step "$WF" "Post the Claude summary comment"

  assert_equal "$status" 0
  refute_planted_ran
  # 这一道不能靠「这一步整个空转」通过：正文照旧是真 jq 解出来的那一段
  assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" '修了 2 条，跳过 1 条'
}

# 九处防线是逐行副本，这一条盯着它们不许各改各的：抽成 $RUNNER_TEMP 下的共享脚本
# 等于把我们自己的防线放到验证命令写得动的地方，所以只能各写一份（合成一份
# 是 MEL-262 的活）。
@test "claude: the summary step filters PATH with the very same block as the push step" {
  pushed="$(trusted_path_block 'Commit and push the Claude fix')"
  commented="$(trusted_path_block 'Post the Claude summary comment')"
  [ -n "$pushed" ] || { echo 'no PATH filter found in the push step' >&2; return 1; }
  assert_equal "$commented" "$pushed"
}

# 跑验证那两步的块里多一行 verify_path="$PATH"（原样那份要留给验证命令自己用），
# 所以整块比不了；能比的是判定本身 —— 九步都得是同一个 path_is_protected。
# 少了这一条，新加一步时照抄漏一行（比如漏掉「相对项不认」那句）没人拦。
@test "claude: all nine credentialed steps share one and the same path guard" {
  guard=''
  for step in 'Verify the Claude fix' 'Commit and push the Claude fix' \
              'Post the Claude summary comment' 'Check the fix outcome' \
              'Decide the takeover' 'Verify the Codex fix' \
              'Commit and push the Codex fix' \
              'Request Codex re-review after a new commit' \
              'Post the Codex summary comment'; do
    this="$(trusted_path_block "$step" |
      awk '/^path_is_protected\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}')"
    [ -n "$this" ] || { echo "no PATH filter in: $step" >&2; return 1; }
    if [ -z "$guard" ]; then guard="$this"; continue; fi
    assert_equal "$this" "$guard" || { echo "drifted in: $step" >&2; return 1; }
  done
}

# ---------- 门禁：谁跑得到验证和推送这两步 ----------

claude_mode_context() {
  gate_reset
  gate_set inputs.runtime shell
  gate_set inputs.review_fixer auto
  gate_set steps.gate.outputs.run true
  gate_set steps.select.outputs.first claude
  gate_set steps.select.outcome success
  gate_set steps.claude_verify.outputs.changed true
}

@test "gating: a Claude round reaches the verify, push and summary steps" {
  claude_mode_context
  gate_trace "$WF"

  gate_ran 'uses: anthropics/claude-code-action@v1'
  gate_ran 'Verify the Claude fix'
  gate_ran 'Commit and push the Claude fix'
  gate_ran 'Post the Claude summary comment'
  gate_ran 'Check the fix outcome'
}

# Claude 压根没跑成（撞额度、令牌失效）：它的改动不可信，验证和推送都不许开始。
# 判定这一轮的 Check the fix outcome 反过来必须照跑，否则失败再没人分类、没人告警。
@test "gating: a provider failure never reaches the verify or push step" {
  claude_mode_context
  gate_fails 'uses: anthropics/claude-code-action@v1'
  gate_trace "$WF"

  gate_skipped 'Verify the Claude fix'
  gate_skipped 'Commit and push the Claude fix'
  gate_skipped 'Post the Claude summary comment'
  gate_ran 'Check the fix outcome'
}

# 验证红了：不推、不发评论，也不许有人把这一轮报成成功。
@test "gating: a rejected verification never reaches the push step" {
  claude_mode_context
  gate_fails 'Verify the Claude fix'
  gate_trace "$WF"

  gate_skipped 'Commit and push the Claude fix'
  gate_skipped 'Post the Claude summary comment'
  gate_skipped 'Check the fix outcome'
  # 裁决点照跑：它看到 outcome 没走完就把这一轮打红，也不会换 Codex 上
  gate_ran 'Decide the takeover'
}

# review_fixer=codex：Claude 没上，它这三步一个都不许跑（否则会拿 Codex 的改动
# 走 Claude 的推送路径，同一轮两个 fixer 各推一笔）。
@test "gating: a codex-only round never reaches the Claude verify or push step" {
  gate_reset
  gate_set inputs.runtime shell
  gate_set inputs.review_fixer codex
  gate_set steps.gate.outputs.run true
  gate_set steps.select.outputs.first codex
  gate_set steps.select.outcome success
  gate_set steps.select.outputs.fallback_allowed false
  # FIRST=codex 时 Decide the takeover 输出 run_codex=true（codex-takeover.bats 有
  # 单块测试保证）；跳过时这些 outputs 会被自动作废，不会假装还在。
  gate_set steps.decide.outputs.run_codex true
  gate_set steps.codex_verify.outputs.changed true
  gate_trace "$WF"

  gate_skipped 'Verify the Claude fix'
  gate_skipped 'Commit and push the Claude fix'
  gate_skipped 'Post the Claude summary comment'
  gate_ran 'Verify the Codex fix'
}
