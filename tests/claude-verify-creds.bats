#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats 每个 @test 是子 shell
# claude-codex-iterate.yml 的 Claude 那条路：被审 PR 自己带的验证命令，跟写权限凭据
# 不许出现在同一步里（MEL-254）。守三件事：
#   1. 跑 Claude 的那一步不给它任何「会执行仓库里代码」的工具，也不让它自己 push ——
#      那一步必须有令牌（action 自己要用），所以只能让 PR 的代码进不来。
#   2. 跑验证的那一步手上什么凭据都没有：没有令牌，也没有 checkout 留在 .git/config
#      里那份。
#   3. 验证动过 .git、改过不许它改的文件、或留下活进程，就红着停下，绝不 commit / push。
# Codex 那条路的同名判定在 codex-takeover.bats。两条路跑的已经是同一段正文
# （Define the fix verify guard / Define the fix push guard 两步各一个函数，MEL-262），
# 差别只有 $FIXER 一个名字 —— 所以这里改一道防线，Codex 那条路同时也改了。

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
  run_block "$WF" "Define the fix verify guard" >/dev/null
  run_block "$WF" "Define the fix push guard" >/dev/null
  # 两条路的验证 / 推送跑的是同一段正文，由这两步的 output 交出来（真跑时由 env: 接
  # 过去），不读 $RUNNER_TEMP 里的文件。
  export FIX_VERIFY_GUARD; FIX_VERIFY_GUARD="$(step_output verify)"
  export FIX_PUSH_GUARD; FIX_PUSH_GUARD="$(step_output push)"
  # 残留清点按运行用户问「名下有谁」，本机上那等于「这台 Mac 上这个用户有谁」——
  # 隔壁 worker 的 bats 一起数进来。把回答这个问题的 ps 换成只认本次 run 的那一份
  # （见 common.bash 里 scope_proc_sweep_to_this_run）。
  scope_proc_sweep_to_this_run
  : >"$GITHUB_OUTPUT"
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
  # 跑验证的确实是这一步：它拿的是验证那份共用正文，而正文里跑的就是 $VERIFY。
  # 改个步骤名、或者哪天忘了把正文递过来，这条就空转不了。
  assert_contains "$keys" 'FIX_VERIFY_GUARD'
  assert_contains "$(fix_guard_body verify_the_fix)" 'bash -euo pipefail -c "$VERIFY"'
  # 带令牌的那一步反过来一个字的验证正文都拿不到：它只拿推送那一份。
  assert_contains "$(step_env_keys "$WF" 'Commit and push the Claude fix')" 'GH_TOKEN'
  refute_contains "$(step_env_keys "$WF" 'Commit and push the Claude fix')" 'FIX_VERIFY_GUARD'
  refute_contains "$(fix_guard_body commit_and_push_the_fix)" 'VERIFY'
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
  # ROUND / REPO 是推送那一步发轮数标记 M7 用的（以前只有 Codex 那半边发，MEL-262
  # 之后两条路都在推送里发）。
  export HEAD_REF=topic PR_NUMBER=7 ROUND=2 REPO=o/r GH_TOKEN=write-token
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

# 只让「提交并推送」那一步信得过假命令目录，验证那一步照旧跑原样的块：轮数标记 M7
# 走 gh，而 gh 只从写不动的目录里找，测试里那个假 gh 放在仓库目录下、过滤之后够不着。
# 验证那一步不能跟着信 —— 假 sleep / 假 date 会把残留清点那几道判定搅了。
verify_then_trusted_push() {
  FAKE_BIN_TRUSTED=
  run_step "$WF" "Verify the Claude fix" || return
  trust_fake_bin
  run_step "$WF" "Commit and push the Claude fix"
}

run_chain_trusted_push() {
  local tries=0
  run verify_then_trusted_push
  while [ "$tries" -lt 3 ] && is_machine_noise; do
    tries=$((tries + 1))
    /bin/sleep 1
    reset_workspace
    run verify_then_trusted_push
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

# ---------- 验证命令跑在哪个用户下（MEL-289） ----------

# 回退路径。bats 自己那个临时目录是 0700，另一个用户连进都进不去，所以不管这台机器
# 有没有免密 sudo，上面那三条自测必然失败 —— 这一条于是在哪儿跑都是回退路径。
# 判据问的是验证命令自己（它报出来的用户名就是我们），不是「日志里有没有那句警告」：
# 静默分离失败和静默不分离长得一模一样，只有问它才分得出。
# fail closed 不是选项：这一步红了，19 个调用方仓库一起推不出修复（MEL-288 的教训）。
@test "claude: a runner that cannot build the dedicated account falls back and still pushes" {
  push_workspace 'id -un >ran-as.txt'

  run_chain

  assert_equal "$status" 0
  assert_contains "$output" 'falling back to the runner user'
  assert_equal "$(cat ran-as.txt)" "$(id -un)"
  assert_equal "$(git show origin/topic:app.txt)" 'v2 fixed by claude'
}

# 逃生阀：哪个仓库的验证命令真离不开 runner 那个用户的 $HOME / 缓存 / 工作区归属，
# 调用桩里写 verify_isolation: off 就留在原地跑，而且不刷那条「这台机器做不到」的
# 警告 —— 那条警告要留给真·少了一层防线的情况。
@test "claude: verify_isolation off keeps the verify command on the runner user" {
  export VERIFY_ISOLATION=off
  push_workspace 'id -un >ran-as.txt'

  run_chain

  assert_equal "$status" 0
  assert_equal "$(cat ran-as.txt)" "$(id -un)"
  refute_contains "$output" 'cannot run the verify command as a dedicated account'
  assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" 'verify_isolation: off'
}

# 开关只从调用方默认分支上的工作流文件来（同 verify_writable_paths）：被审 PR 改不到
# 它。拼错当场红 —— `of` / `false` / `no` 被当成「不是 off」就还是 auto，反过来
# 静默少一层防线才是这里最怕的（同模型 / 力度那两条白名单）。
@test "claude: the dedicated-account switch comes from the caller's workflow file only" {
  for step in 'Verify the Claude fix' 'Verify the Codex fix'; do
    assert_contains "$(step_env_keys "$WF" "$step")" 'VERIFY_ISOLATION'
  done
  # shellcheck disable=SC2016  # 找的就是字面量 ${{
  assert_contains "$(cat "$REPO_ROOT/$WF")" 'VERIFY_ISOLATION: ${{ inputs.verify_isolation }}'

  export RUNTIME=shell VERIFY_OVERRIDE='' CLAUDE_MODEL=claude-opus-5-5 CLAUDE_EFFORT=xhigh
  export VERIFY_ISOLATION=sometimes
  run run_block "$WF" "Resolve runtime defaults"
  assert_equal "$status" 1
  assert_contains "$output" 'is not one of auto, off'
}

# ---------- 真的换了一个用户（只有 Linux runner 上跑得到） ----------

# 工作区和 $RUNNER_TEMP 都搬到「另一个用户走得进去」的地方：bats 给的那个 0700 目录
# 下面，三条自测必然失败、必然回退（上面第一条测的就是那个），分离路径一个字都跑不到。
separated_workspace() { # separated_workspace <verify script>
  command -v useradd >/dev/null 2>&1 ||
    skip 'no useradd here; the dedicated account only exists on Linux runners'
  sudo -n true >/dev/null 2>&1 ||
    skip 'no passwordless sudo here; the dedicated account needs it'
  SEP_ROOT="$(mktemp -d /tmp/mel289-sep-XXXXXX)"
  chmod 0711 "$SEP_ROOT"
  export RUNNER_TEMP="$SEP_ROOT/runner-temp"
  export GITHUB_WORKSPACE="$SEP_ROOT/work"
  mkdir -p "$RUNNER_TEMP" "$GITHUB_WORKSPACE"
  cd "$GITHUB_WORKSPACE" || return 1
  push_workspace "$1"
}

# 逃出去的进程我们自己 kill 不动，收尾也得借 sudo。
reap_separated_account() {
  sudo -n pkill -U ghwf-verify >/dev/null 2>&1 || true
}

# 本票的那条性质，正面证明：验证命令跑在另一个 uid 下，连「同一个用户」这个读
# /proc/<pid>/environ 的资格都没有了 —— 它去读我们这一步的进程环境被内核当场拒掉。
# 回退路径上它读得到（只是那份环境里没有令牌，MEL-254），所以这一条是分离路径独有的。
# 顺带钉住那两件最容易做坏的事：它照旧写得动工作区（.venv / 锁文件），而它造出来的
# 目录我们回头删得掉（下一轮交接前要 git clean -fdx）。
@test "claude: the verify command runs as a dedicated account that cannot read our environ" {
  export VERIFY_WRITABLE_PATHS=deps.lock
  separated_workspace 'id -un >ran-as.txt
if cat "/proc/$PPID/environ" >environ-read.txt 2>environ-err.txt; then echo yes; else echo no; fi >environ-verdict.txt
if sudo -n true 2>/dev/null; then echo yes; else echo no; fi >sudo-verdict.txt
mkdir -p .venv && printf x >.venv/marker
printf "lock v2\n" >deps.lock'

  run verify_and_push
  reap_separated_account

  assert_equal "$status" 0
  assert_equal "$(cat ran-as.txt)" 'ghwf-verify'
  assert_equal "$(cat environ-verdict.txt)" 'no'
  assert_contains "$(cat environ-err.txt)" 'Permission denied'
  # 这个账号不在 sudoers 里，所以「验证命令真要动 sudo 就能绕过上面这一整串」那一条
  # （README 里那句）在这条路上不成立
  assert_equal "$(cat sudo-verdict.txt)" 'no'
  # 跑完就把它从工作区那个组里摘出去：排一个「过后再跑」的任务（cron）绕得过
  # 「此刻名下没人」那道清点，但起来时拿不到这个组，也就动不了这棵树（Codex 2026-10-02
  # 在 PR #32 上的 P1）。
  refute_contains " $(id -nG ghwf-verify) " " $(ls -ld "$PWD" | awk '{ print $4 }') "
  assert_equal "$(git show origin/topic:deps.lock)" 'lock v2'
  # 它造出来的目录归属对不对，只有真删一次才知道
  git clean -qfdx
  [ ! -e .venv ] || { echo '.venv outlived git clean: the ownership grant is wrong' >&2; return 1; }
}

# 「加进工作区那个组」是它写得动工作区的办法，但那个组自己带权限的时候（自建 runner
# 上工作区的组正好是 docker = 等于 root 并不罕见），这一步就不是「降权跑」而是「升权跑」。
# 判据：把工作区的组换成 docker，分离必须拒绝、退回 runner 用户。
@test "claude: a privileged workspace group is refused instead of handed to the account" {
  separated_workspace 'id -un >ran-as.txt'
  chgrp docker "$PWD" 2>/dev/null || skip 'this machine has no docker group to borrow'

  run run_step "$WF" "Verify the Claude fix"

  assert_equal "$status" 0
  assert_contains "$output" 'cannot run the verify command as a dedicated account'
  assert_equal "$(cat ran-as.txt)" "$(id -un)"
}

# 验证命令躲出进程组（setsid）之后，那一步**返回成功的时候**那个账号名下必须一个活
# 进程都没有 —— 这就是下一步敢导出令牌的全部前提。两种结局都合法，判据是同一条：
#   ① hosted runner 的 /etc/sudoers 写着 `Defaults use_pty`（2026-10-02 实测），sudo
#      收尾时连 setsid 出去的那个一起收掉了 —— 这一步照旧绿，而账号名下是空的；
#   ② 它真活下来了 —— 按 uid 清点把整轮红着停下（回退路径上那条同名测试盯的就是
#      这一半，两条路跑的是同一段正文）。
# 不许出现的是第三种：这一步绿了、而它还活着。
@test "claude: a setsid escapee under the dedicated account never outlives the verify step" {
  separated_workspace 'setsid sleep 30 >/dev/null 2>&1 &
echo "$!" >escaped.pid'

  run run_step "$WF" "Verify the Claude fix"
  alive="$(ps -U ghwf-verify -o pid= 2>/dev/null || true)"
  reap_separated_account

  if [ "$status" -eq 0 ]; then
    [ -z "$alive" ] || {
      echo "the step passed while the account still owned: $alive" >&2
      return 1
    }
  else
    assert_contains "$output" 'outlived the verify command'
    assert_contains "$output" 'ghwf-verify'
    assert_equal "$(git rev-parse HEAD)" "$(git rev-parse origin/topic)"
  fi
}

# ---------- 问不出来不等于名下没人（Codex 2026-10-02 在 PR #32 上的两条 P1）----------

# 共用正文里的一个嵌套函数，按 workflow 里写的样子取出来（同 fix_guard_body，再往里
# 剥一层缩进）。单独跑它是因为这几道判定问的是「问不出来的时候它怎么答」，而真造一台
# procfs 配了 hidepid 的机器、或者一个 /etc 写不动的 runner，不是测试干得了的事。
# 整个函数定义原样交出来（连 `name() {` 和收尾那个 `}`），再剥掉一层缩进。
# 开头那一行用前缀比，不用等号比：定义行后面可能跟着一句行内注释。
verify_helper() { # verify_helper <嵌套函数名>
  fix_guard_body verify_the_fix |
    awk -v fn="$1() {" '
      index($0, fn) == 1 { f = 1; print; next }
      f && $0 == "}"     { print; exit }
      f                  { sub(/^  /, ""); print }
    '
}

# 把取出来的函数接上桩跑一遍。PATH 钉死在系统目录：fake-bin 里那个假 sleep 不真睡，
# 会把下面这几条「轮询到看见」的判定搅成空转。
run_helper() { # run_helper <桩脚本> <嵌套函数名>...
  local stub="$1" fn
  shift
  { printf 'PATH=/usr/bin:/bin\nset -uo pipefail\n'
    for fn in "$@"; do verify_helper "$fn"; done
    cat "$stub"
  } >"$BATS_TEST_TMPDIR/helper-probe.sh"
  bash "$BATS_TEST_TMPDIR/helper-probe.sh"
}

# 专用账号的 uid 不是我们，procfs 配了 hidepid 的机器上普通身份一个也看不见 ——
# 而「看不见」就是这道清点的放行条件。所以别的 uid 必须借 root 的身份去问；
# 我们自己那个照旧直接问（回退路径不要求有 sudo）。
@test "claude: the dedicated account's process sweep is asked with root privilege" {
  cat >"$BATS_TEST_TMPDIR/stub.sh" <<'EOS'
self_uid=1000
as_root() { printf 'via-sudo '; "$@"; }
ps() { printf '%s\n' "ps $*"; }
printf 'self: %s\n' "$(ps_by_uid 1000 pid=)"
printf 'other: %s\n' "$(ps_by_uid 4242 pid=)"
EOS

  run run_helper "$BATS_TEST_TMPDIR/stub.sh" ps_by_uid

  assert_equal "$status" 0
  assert_contains "$output" 'other: via-sudo ps -U 4242 -o pid='
  assert_contains "$output" 'self: ps -U 1000 -o pid='
  # 整段正文里只有 ps_by_uid 碰得到 `ps -U`：别处再写一条，就又多一个绕开 root 身份
  # 的入口，而那条入口在 hidepid 的机器上会一路报「名下没人」。
  assert_equal "$(fix_guard_body verify_the_fix | grep -c 'ps -U "')" 2
  assert_equal "$(verify_helper ps_by_uid | grep -c 'ps -U "')" 2
}

# `ps -U` 在「一个进程都没有」的时候退 1 且不输出，在「问不出来」的时候也可以是同一副
# 长相 —— 前者照旧放行（专用账号名下本来就该是空的），后者必须往上报失败。以前这里
# 一律 `|| true` 当成空，于是整道清点在问不动的机器上变成一个看不见的空操作。
@test "claude: a process sweep that cannot be answered is not read as an empty account" {
  cat >"$BATS_TEST_TMPDIR/stub.sh" <<'EOS'
self_uid=1000
as_root() { "$@"; }
ps() { exit "${PS_EXIT:-0}"; }
if out="$(ps_by_uid 4242 pid=)"; then printf 'answered:[%s]\n' "$out"; else printf 'unanswerable\n'; fi
EOS

  PS_EXIT=1 run run_helper "$BATS_TEST_TMPDIR/stub.sh" ps_by_uid
  assert_equal "$output" 'answered:[]'

  PS_EXIT=2 run run_helper "$BATS_TEST_TMPDIR/stub.sh" ps_by_uid
  assert_equal "$output" 'unanswerable'

  # 上面那一层往上报了，user_procs 这一层也不许吞：它才是清点真正调的那个。
  cat >"$BATS_TEST_TMPDIR/procs.sh" <<'EOS'
verify_uid=4242
ps_by_uid() { [ "${PS_OK:-1}" = 1 ] || return 1; printf '%s\n' "${PS_OUT:-}"; }
if out="$(user_procs)"; then printf 'answered:[%s]\n' "$out"; else printf 'unanswerable\n'; fi
EOS

  PS_OK=0 run run_helper "$BATS_TEST_TMPDIR/procs.sh" user_procs
  assert_equal "$output" 'unanswerable'

  PS_OK=1 PS_OUT='111 1 S Thu Oct 2 10:00:00 2026 /bin/sleep 9' \
    run run_helper "$BATS_TEST_TMPDIR/procs.sh" user_procs
  assert_equal "$output" 'answered:[111|1|Thu Oct 2 10:00:00 2026|/bin/sleep 9]'
}

# 验证跑完那道清点同理：问不出来要红，而且报的是「这道门自己坏了」，不是「名下没人」。
# 放过的后果不是「少一层保险」而是真能漏：一个躲出去的进程手里那把工作区写权限不会
# 因为我们事后把账号摘出组而消失，它就能在「验证通过」和「提交推送」之间换掉要提交的内容。
@test "claude: an unanswerable post-verify sweep goes red instead of passing as contained" {
  cat >"$BATS_TEST_TMPDIR/stub.sh" <<'EOS'
verify_procs_baseline=''
verify_leftovers=''
verify_sweep_unanswerable=''
user_procs() { [ "${PROCS_OK:-1}" = 1 ] || return 1; printf '%s' "${PROCS:-}"; }
if verify_tree_is_contained; then
  printf 'contained\n'
else
  printf 'red unanswerable=%s leftovers=[%s]\n' "${verify_sweep_unanswerable:-}" "$verify_leftovers"
fi
EOS

  # 问得出来、名下没有多余的 → 放行
  PROCS_OK=1 PROCS='' run run_helper "$BATS_TEST_TMPDIR/stub.sh" unexplained_procs verify_tree_is_contained
  assert_equal "$output" 'contained'

  # 问不出来 → 红
  PROCS_OK=0 run run_helper "$BATS_TEST_TMPDIR/stub.sh" unexplained_procs verify_tree_is_contained
  assert_equal "$output" 'red unanswerable=1 leftovers=[]'

  # 这一步真跑起来确实走这条分支，而且报的那句跟「真有残留」那句分得开
  assert_contains "$(fix_guard_body verify_the_fix)" 'refusing to read an unanswerable sweep as containment'
}

# 正面自测：跑验证之前先在那个账号下起一个睡两秒的进程，确认清点真能看见它。
# 看不见就回退，不声称已经隔离 —— 这是「清点问得出来」唯一的直接证据，光看 `ps` 的
# 退出码分不出「看不见」和「名下没人」。
# 真的两个 uid 只有 Linux runner 上有（下面 separated_workspace 那几条测的就是那一半：
# 分离成功 = 这道自测在真账号上过了）；这里钉的是「看不见的时候它拒绝」。
@test "claude: isolation is refused unless a probe process under the account is actually seen" {
  cat >"$BATS_TEST_TMPDIR/stub.sh" <<'EOS'
self_uid=1000
verify_account=probe-account
# 迷你 sudo：认 -E 和 -u <用户>，剩下的照原样跑。
as_root() {
  while [ "$#" -gt 0 ]; do
    case "$1" in -E) shift ;; -u) shift 2 ;; *) break ;; esac
  done
  "$@"
}
# 第 2 次问的时候报回一个 pid（探针这时候活着），其余报空；blind 一律空手而归 ——
# 那正是 hidepid 机器上别人的进程的长相。
ps() {
  n=$(( $(cat "$BATS_TEST_TMPDIR/ps-calls" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$n" >"$BATS_TEST_TMPDIR/ps-calls"
  [ "${BLIND:-0}" = 1 ] && exit 1
  [ "$n" -ne 2 ] || { printf '4242\n'; exit 0; }
  exit 1
}
if the_sweep_can_see_that_account 4242; then printf 'seen\n'; else printf 'blind\n'; fi
EOS

  BLIND=0 run run_helper "$BATS_TEST_TMPDIR/stub.sh" ps_by_uid the_sweep_can_see_that_account
  assert_equal "$output" 'seen'

  : >"$BATS_TEST_TMPDIR/ps-calls"
  BLIND=1 run run_helper "$BATS_TEST_TMPDIR/stub.sh" ps_by_uid the_sweep_can_see_that_account
  assert_equal "$output" 'blind'

  # 自测证不出来就回退（return 1 一路传到调用处那条 warning），不是只记一笔往下走
  assert_contains "$(fix_guard_body verify_the_fix)" 'the_sweep_can_see_that_account "$uid" || return 1'
}

# 「不准排定时任务」那一步失败不许静默跳过：拒绝名单是「排一个任务在清点之后起来」
# 唯一的拦截点，而那个任务起来时拿到的工作区写权限，事后摘组也收不回来。写不进去
# 就整条回退到 runner 用户那条路（调用处会刷那条 warning），不再嘴上声称已经隔离。
@test "claude: failing to deny the account scheduled jobs refuses isolation instead of skipping" {
  cat >"$BATS_TEST_TMPDIR/stub.sh" <<'EOS'
verify_account=probe-account
seen="$BATS_TEST_TMPDIR/deny-seen.txt"
: >"$seen"
# 名单文件用 root 的身份读写（ubuntu 上 /etc/at.deny 是 0640 root:daemon）。
as_root() {
  case "$1" in
    grep) grep -qxF "$verify_account" "$seen" 2>/dev/null ;;
    tee) [ "${TEE_OK:-1}" = 1 ] || return 1; cat >>"$seen" ;;
    *) return 1 ;;
  esac
}
if deny_the_account_scheduled_jobs; then printf 'denied\n'; else printf 'refused\n'; fi
printf 'lines=%s\n' "$(grep -c . "$seen" 2>/dev/null || echo 0)"
EOS

  # 写进去了 → 继续走分离这条路；第二个名单文件读到已经有它就跳过，不重复追加
  TEE_OK=1 run run_helper "$BATS_TEST_TMPDIR/stub.sh" deny_the_account_scheduled_jobs
  assert_contains "$output" 'denied'
  assert_contains "$output" 'lines=1'

  # 写不进去 → 拒绝，绝不静默跳过
  TEE_OK=0 run run_helper "$BATS_TEST_TMPDIR/stub.sh" deny_the_account_scheduled_jobs
  assert_contains "$output" 'refused'

  # 拒绝要一路传到调用处：以前这里是 `|| true`，写回去这条就红
  assert_contains "$(fix_guard_body verify_the_fix)" 'deny_the_account_scheduled_jobs || return 1'
  refute_contains "$(verify_helper deny_the_account_scheduled_jobs)" '|| true'
}

# ---------- 捡到的账号原本在哪些组里（Codex 2026-10-02 在 PR #32 `69027b4` 上的 P1）----------

# 那个专用账号可能在我们跑之前机器上就已经有了（自建 runner 上有 root 的人提前建好）。
# 它原本在哪些组里是别人定的，而组自带权限：塞进 docker 就等于能拿 root。原来这里只
# 查了「它的 uid 不是 0」和「我们要给它加进去的那个工作区组不带权限」—— 漏的正是它
# 自己原有的组，于是分离这一步会把被审 PR 自己带的命令交到一个等于 root 的身份上去跑，
# 比压根不分离还糟。
# 判据必须是白名单（只允许它的主组 + 工作区那个组），不能拿特权组名单去比：名单是
# 列举、列不全 —— 随便起个名字的组也能在 /etc/sudoers.d 里被写成等于 root。
#
# 这两条跑的是 workflow 里那个函数本身，外部命令全接桩：真造一台「账号已经建好并塞进
# docker」的机器要 root 去改这台机器的 /etc/group，不是测试干得了的事。
separate_user_stub() { # separate_user_stub >桩脚本
  cat <<'EOS'
verify_account=probe-account
verify_ws="$BATS_TEST_TMPDIR/sep-work"
RUNNER_TEMP="$BATS_TEST_TMPDIR/sep-temp"
mkdir -p "$verify_ws" "$RUNNER_TEMP"
verify_user=''
verify_sandbox=''
verify_uid=''
verify_group=''
# 标记那一套另有自己的测试（下一条），这里只要让它别在「问不出这是哪一次 run」上回退
GITHUB_RUN_ID=7
GITHUB_RUN_ATTEMPT=1
created="$BATS_TEST_TMPDIR/useradd-ran"

# sudo 一律当成有：本机有没有 sudo 跟这两条要钉的东西无关
command() { [ "$*" = '-v sudo' ] || { builtin command "$@"; return; }; }
# 迷你 sudo：认 -E 和 -u <用户>，useradd 记一笔，id 透传给下面那个桩，其余一律成功
as_root() {
  while [ "$#" -gt 0 ]; do
    case "$1" in -E) shift ;; -u) shift 2 ;; *) break ;; esac
  done
  case "$1" in
    useradd) : >"$created" ;;
    id) shift; id "$@" ;;
    *) : ;;
  esac
}
# 这台机器上那个账号长什么样，由四个入参摆出来（run_separate 每次全给，省得上一条
# 的设定漏到下一条）；没建起来之前 `id -u` 问不到它
id() {
  case "$1" in
    -u) { [ "$ACCOUNT_EXISTS" = 1 ] || [ -e "$created" ]; } && printf '4242\n' ;;
    -gn) printf '%s\n' "$ACCOUNT_PRIMARY" ;;
    -g) printf '%s\n' "$ACCOUNT_PRIMARY_GID" ;;
    -nG) printf '%s\n' "$ACCOUNT_GROUPS" ;;
    *) return 1 ;;
  esac
}
# 工作区那个组是 ls 的第 4 列（workflow 里就是这么取的）
ls() { printf 'drwxrwsr-x 2 runner runner 4096 Oct 2 10:00 .\n'; }
# 这几道判定各有自己的测试，这里一律放行
deny_the_account_scheduled_jobs() { return 0; }
ps_by_uid() { printf ''; }
the_sweep_can_see_that_account() { return 0; }
the_account_is_ours_from_this_run() { return 0; }
mark_the_account_as_ours() { return 0; }

if separate_the_verify_user; then
  printf 'separated group=%s\n' "$verify_group"
else
  printf 'fell-back\n'
fi
if [ -e "$created" ]; then printf 'useradd=yes\n'; else printf 'useradd=no\n'; fi
EOS
}

# 四个入参每次都给齐：bats 的 `run` 是函数，`VAR=x run f` 这种前缀赋值在 bash 里会留
# 在当前 shell 上，少给一个就会悄悄沿用上一条的设定、把判定做成假绿。
run_separate() { # run_separate <账号已存在 0|1> <主组名> <主组 gid> <全部组>
  ACCOUNT_EXISTS="$1" ACCOUNT_PRIMARY="$2" ACCOUNT_PRIMARY_GID="$3" ACCOUNT_GROUPS="$4" \
    run_helper "$BATS_TEST_TMPDIR/stub.sh" \
      separate_the_verify_user account_groups_are_unprivileged group_is_privileged
}

@test "claude: a pre-existing account is refused unless every group it is already in is allow-listed" {
  separate_user_stub >"$BATS_TEST_TMPDIR/stub.sh"

  # 它原本就在 docker 里 → 回退，不拿来跑
  run run_separate 1 probe-account 4242 'probe-account docker'
  assert_equal "$status" 0
  assert_contains "$output" 'fell-back'
  assert_contains "$output" 'useradd=no'

  # 名字不在那张特权名单上的组同样不行：判据是白名单，不是拿名单去比
  run run_separate 1 probe-account 4242 'probe-account ci-helpers'
  assert_contains "$output" 'fell-back'

  # 主组自己就是特权组 → 回退
  run run_separate 1 docker 4242 'docker'
  assert_contains "$output" 'fell-back'

  # 主组的 gid 是 0（换了个不在名单上的名字也一样）→ 回退
  run run_separate 1 staff 0 'staff'
  assert_contains "$output" 'fell-back'

  # 组问不出来（id 答不上）不许读成「没有多余的组」
  run run_separate 1 probe-account 4242 ''
  assert_contains "$output" 'fell-back'

  # 只在自己的主组里 → 照旧走分离（这一条同时兜住「函数名写错、压根没取到」：取不到
  # 的话上面那几条会因为「命令不存在」而假绿）
  run run_separate 1 probe-account 4242 'probe-account'
  assert_contains "$output" 'separated group=runner'

  # 同一个 job 里第二次复用：它还在工作区那个组里，那是我们上一轮加的，放行
  run run_separate 1 probe-account 4242 'probe-account runner'
  assert_contains "$output" 'separated group=runner'

  # 这道检查真的挂在那条主路上（撤掉调用点，上面那几条立刻变红）
  assert_contains "$(fix_guard_body verify_the_fix)" 'account_groups_are_unprivileged "$group"'
  # 特权组名单只有一份：两份会各自漂，而漂掉的那份正好是没人看的那份
  assert_equal "$(fix_guard_body verify_the_fix | grep -c 'root|sudo|wheel|admin|adm|docker')" 1
}

@test "claude: an account we create ourselves still takes the separation path" {
  separate_user_stub >"$BATS_TEST_TMPDIR/stub.sh"

  # 机器上原本没有它 → 我们建，建完照旧走分离：useradd --system 只给它一个同名主组，
  # 没有「别人塞进去的组」这回事，所以上面那道白名单不该拦它
  run run_separate 0 probe-account 4242 'probe-account'

  assert_equal "$status" 0
  assert_contains "$output" 'separated group=runner'
  assert_contains "$output" 'useradd=yes'
}

# ---------- 这个账号是不是我们这一次 run 建的（Codex 2026-10-03 在 PR #32 `d18d0f9` 上的 P1）----------

# 捡一个机器上本来就有的账号来跑被审 PR 自己带的命令，等于把它身上带着的东西一起接过
# 来，而那是一整类：已经排好的 crontab、at 队列里等着的任务、cron.allow / at.allow 里的
# 名字（allow 比 deny 优先，所以写拒绝名单压根没用）、linger 起来的 systemd 用户定时器。
# 逐条去清永远清不全，所以整类一起关掉：不是这一次 run 里我们建的就不分离、回退原路径。
# 证据必须是验证命令伪造不了的那种：root 写在 /run/ghwf-verify/ 下（0700 root:root，那个
# 账号连 cd 都进不去）、文件名带 GITHUB_RUN_ID + GITHUB_RUN_ATTEMPT 的一份标记 —— 上一次
# run 留下的标记认不了这一次。
# 这几条跑的是 workflow 里那几个函数本身，碰文件系统的全走 as_root、整段接桩：真造一台
# 「账号跨 run 留在机器上」的机器要 root 去改这台机器的 /etc/passwd。
marker_stub() { # marker_stub >桩脚本
  cat <<'EOS'
verify_account=probe-account
verify_ws="$BATS_TEST_TMPDIR/mark-work"
RUNNER_TEMP="$BATS_TEST_TMPDIR/mark-temp"
mkdir -p "$verify_ws" "$RUNNER_TEMP"
verify_user=''
verify_sandbox=''
verify_uid=''
verify_group=''
verify_bash=''
# 每一条从零开始：$BATS_TEST_TMPDIR 在同一个 @test 里几次调用之间是共用的，上一条留下的
# 「建过账号」/「标记落地过」会把下一条判定做成假绿。
state="$(mktemp -d)"
created="$state/useradd-ran"
marked="$state/marker-landed"
GITHUB_RUN_ID="$RUN_ID"
GITHUB_RUN_ATTEMPT="$RUN_ATTEMPT"
if [ "$MARKER_PRESENT" = 1 ]; then : >"$marked"; fi

command() { [ "$*" = '-v sudo' ] || { builtin command "$@"; return; }; }
# 迷你 sudo。标记那几步都走它：`test ! -L` 按入参答「是不是快捷方式」，`test -O` 答
# 「在不在 + 是不是 root 的」，`tee` 按 MARKER_WRITE_OK 决定内容落不落地，`cat` 只在真
# 落地了的时候报回标记里装的 uid。
as_root() {
  while [ "$#" -gt 0 ]; do
    case "$1" in -E) shift ;; -u) shift 2 ;; *) break ;; esac
  done
  case "$1" in
    useradd) : >"$created" ;;
    id) shift; id "$@" ;;
    test)
      shift
      case "$1" in
        '!') [ "$MARKER_SYMLINK" != 1 ] ;;
        -O)  [ -e "$marked" ] && [ "$MARKER_OWNER" = 0 ] ;;
        *)   : ;;
      esac ;;
    tee)
      if [ "$MARKER_WRITE_OK" != 1 ]; then return 1; fi
      : >"$marked" ;;
    cat)
      if [ ! -e "$marked" ]; then return 1; fi
      printf '%s\n' "$MARKED_UID" ;;
    *) : ;;
  esac
}
# 没建起来之前 `id -u` 问不到它；组那一套另有自己的测试，这里一律给「只在自己主组里」
id() {
  case "$1" in
    -u) { [ "$ACCOUNT_EXISTS" = 1 ] || [ -e "$created" ]; } && printf '4242\n' ;;
    -gn) printf 'probe-account\n' ;;
    -g) printf '4242\n' ;;
    -nG) printf 'probe-account\n' ;;
    *) return 1 ;;
  esac
}
ls() { printf 'drwxrwsr-x 2 runner runner 4096 Oct 3 10:00 .\n'; }
deny_the_account_scheduled_jobs() { return 0; }
ps_by_uid() { printf ''; }
the_sweep_can_see_that_account() { return 0; }

if separate_the_verify_user; then
  printf 'separated group=%s\n' "$verify_group"
else
  printf 'fell-back\n'
fi
if [ -e "$created" ]; then printf 'useradd=yes\n'; else printf 'useradd=no\n'; fi
if [ -e "$marked" ]; then printf 'marker=yes\n'; else printf 'marker=no\n'; fi
EOS
}

# 八个入参每次都给齐，同上面 run_separate：bats 的 `run` 是函数，`VAR=x run f` 这种前缀
# 赋值在 bash 里会留在当前 shell 上，少给一个就会悄悄沿用上一条的设定、把判定做成假绿。
run_marker() { # run_marker <账号已存在 0|1> <标记已在 1|0> <标记属主 uid> <标记是快捷方式 0|1> <写标记成功 1|0> <run 号> <重跑次数> <标记里装的 uid>
  ACCOUNT_EXISTS="$1" MARKER_PRESENT="$2" MARKER_OWNER="$3" MARKER_SYMLINK="$4" \
    MARKER_WRITE_OK="$5" RUN_ID="$6" RUN_ATTEMPT="$7" MARKED_UID="$8" \
    run_helper "$BATS_TEST_TMPDIR/stub.sh" \
      separate_the_verify_user the_account_is_ours_from_this_run \
      mark_the_account_as_ours account_groups_are_unprivileged group_is_privileged
}

@test "claude: an account the machine already had is refused unless this run is the one that created it" {
  marker_stub >"$BATS_TEST_TMPDIR/stub.sh"

  # 账号已经在机器上，而这一次 run 没留下过标记 → 回退，不拿它来跑
  run run_marker 1 0 0 0 1 7 1 4242
  assert_equal "$status" 0
  assert_contains "$output" 'fell-back'
  assert_contains "$output" 'useradd=no'

  # 同一个 job 里第二次复用：标记是我们这一轮自己写下的 → 照旧分离
  run run_marker 1 1 0 0 1 7 1 4242
  assert_contains "$output" 'separated group=runner'
  assert_contains "$output" 'useradd=no'

  # 标记不是 root 写的 → 回退：/run 要是谁都写得动，那个账号自己就能种一份（run 号在
  # 它的环境里），而它种出来的属主是它自己
  run run_marker 1 1 1001 0 1 7 1 4242
  assert_contains "$output" 'fell-back'

  # 标记是个快捷方式 → 回退：指向别处的链接会让那句 cat 读到别处去
  run run_marker 1 1 0 1 1 7 1 4242
  assert_contains "$output" 'fell-back'

  # 问不出这是哪一次 run（run 号或重跑次数少一个）→ 回退
  run run_marker 1 1 0 0 1 '' 1 4242
  assert_contains "$output" 'fell-back'
  run run_marker 1 1 0 0 1 7 '' 4242
  assert_contains "$output" 'fell-back'

  # 标记在、但装的是别的 uid（账号被人删掉重建过）→ 回退
  run run_marker 1 1 0 0 1 7 1 9999
  assert_contains "$output" 'fell-back'

  # 机器上原本没有它 → 我们建，建完留标记，照旧分离
  run run_marker 0 0 0 0 1 7 1 4242
  assert_contains "$output" 'separated group=runner'
  assert_contains "$output" 'useradd=yes'
  assert_contains "$output" 'marker=yes'

  # 建起来了但标记写不进去 → 回退：写不下证据就证明不了下一次复用的是我们这个账号
  run run_marker 0 0 0 0 0 7 1 4242
  assert_contains "$output" 'fell-back'
  assert_contains "$output" 'marker=no'

  # 这两道真的挂在那条主路上（撤掉调用点，上面那几条立刻变红）
  assert_contains "$(fix_guard_body verify_the_fix)" \
    'mark_the_account_as_ours "$uid" "$marker" || return 1'
  assert_contains "$(fix_guard_body verify_the_fix)" \
    'the_account_is_ours_from_this_run "$uid" "$marker" || return 1'
  # 标记放在哪只有一份：两份会各自漂，而漂掉的那份正好是没人看的那份
  assert_equal "$(fix_guard_body verify_the_fix | grep -c '/run/ghwf-verify\.')" 1
}

# ---------- 放宽写权限那句 umask 到不到得了验证进程（Codex 2026-10-03 在 `d18d0f9` 上的 P1）----------

# sudo 把 umask 取「调用者的」和 sudoers 里那个（默认 0022）的并集，所以 umask 002 设在
# sudo 外面到不了验证进程：它造出来的 .venv / node_modules 于是是 0755，组写不动 ——
# runner 回头 add -u 写不动、git clean -fdx 也删不掉（深层尤其：要删 .venv/a/b 得先写得动
# .venv/a）。所以那句 umask 要设在 sudo 起的那条命令里面。
# 这一条不是结构判定：桩只把 sudo 那一层剥掉，正文里那条启动命令原样跑（env + 里面那层
# shell），外层先把 umask 收成 022（sudo 之后验证进程看到的就是这个），验证命令报回自己
# 的 umask。设在里面报 0002，挪回外层就报 0022 —— 这一条当场变红。
launch_stub() { # launch_stub >桩脚本
  cat <<'EOS'
verify_user=ghwf-verify
verify_sandbox="$BATS_TEST_TMPDIR/launch-sandbox"
decoy="$BATS_TEST_TMPDIR/launch-decoy"
mkdir -p "$verify_sandbox/home" "$decoy"
verify_path="$PATH"
verify_bash=/bin/bash
[ -x "$verify_bash" ] || verify_bash=/usr/bin/bash
VERIFY='umask'
# 迷你 sudo：把 `-E -u <用户>` 剥掉，剩下的原样跑
as_root() {
  while [ "$#" -gt 0 ]; do
    case "$1" in -E) shift ;; -u) shift 2 ;; *) break ;; esac
  done
  "$@"
}
umask 022
launch_the_verify_command
EOS
}

@test "claude: the cooperative umask is set inside the sudo command, where the verify process still sees it" {
  launch_stub >"$BATS_TEST_TMPDIR/stub.sh"

  run run_helper "$BATS_TEST_TMPDIR/stub.sh" launch_the_verify_command

  # 外层是 022，验证命令报回 0002 = 那句 umask 是里面那层设的
  assert_equal "$status" 0
  assert_equal "$output" '0002'

  # 外层那句连同它的存档/还原一起没了（留着就是两处管同一件事，而外面那处不生效）
  refute_contains "$(fix_guard_body verify_the_fix)" 'saved_umask'
  assert_contains "$(verify_helper launch_the_verify_command)" "-c 'umask 002; exec"
  # 里面那层 shell 走绝对路径，不靠 PATH 找：PATH 在这条命令里已经换成验证命令自己那一
  # 份（没过滤），靠它找 bash 等于让被审 PR 自己挑一个（MEL-278）
  assert_contains "$(verify_helper launch_the_verify_command)" '"$verify_bash" -euo pipefail'
  assert_contains "$(fix_guard_body verify_the_fix)" 'for candidate in /bin/bash /usr/bin/bash'
  assert_contains "$(fix_guard_body verify_the_fix)" '[ -n "$verify_bash" ] || return 1'
  # 回退路径一个字不改：它照旧是原来那一句，没有 umask、也不该有
  assert_contains "$(verify_helper launch_the_verify_command)" 'bash -euo pipefail -c "$VERIFY"'
}

# ---------- 两条路共用同一段正文 ----------

# MEL-262 的那条不变量：验证和推送各只有一份正文，两条路都跑它，差别只有 $FIXER
# 一个名字。谁要是把哪一边重新拆成自己的一份，这一条就红。
@test "claude: both paths run the one shared verify body and the one shared push body" {
  for step in 'Verify the Claude fix' 'Verify the Codex fix'; do
    assert_contains "$(step_env_keys "$WF" "$step")" 'FIX_VERIFY_GUARD'
    assert_contains "$(extract_run_block "$REPO_ROOT/$WF" "$step")" 'verify_the_fix'
    # 跑验证的那一步拿不到推送正文
    refute_contains "$(step_env_keys "$WF" "$step")" 'FIX_PUSH_GUARD'
  done
  for step in 'Commit and push the Claude fix' 'Commit and push the Codex fix'; do
    assert_contains "$(step_env_keys "$WF" "$step")" 'FIX_PUSH_GUARD'
    assert_contains "$(extract_run_block "$REPO_ROOT/$WF" "$step")" 'commit_and_push_the_fix'
  done
  # 两条路差的就是这一个名字
  assert_contains "$(step_env_literals "$WF" 'Verify the Claude fix')" 'FIXER=Claude'
  assert_contains "$(step_env_literals "$WF" 'Verify the Codex fix')" 'FIXER=Codex'
  assert_contains "$(step_env_literals "$WF" 'Commit and push the Claude fix')" 'FIXER=Claude'
  assert_contains "$(step_env_literals "$WF" 'Commit and push the Codex fix')" 'FIXER=Codex'
  # 四步都得失败关闭：正文没递过来就红着停下，别带着半截防线往下跑
  for step in 'Verify the Claude fix' 'Verify the Codex fix' \
              'Commit and push the Claude fix' 'Commit and push the Codex fix'; do
    assert_contains "$(extract_run_block "$REPO_ROOT/$WF" "$step")" 'did not arrive from the Define step'
  done
}

# 正文没递过来就红着停下（跟「没拿到告警函数」同一个处置）：带着半截防线去跑被审
# PR 自己带的命令，等于一道判定都没有。两条路共用这段正文，所以验一边就够。
@test "claude: without the verify guard from the Define step the round goes red" {
  push_workspace 'printf "smuggled\n" >app.txt'
  export FIX_VERIFY_GUARD=''

  run run_step "$WF" "Verify the Claude fix"

  assert_equal "$status" 1
  assert_contains "$output" 'verify guard did not arrive'
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse origin/topic)"
}

# 推送那一步同理：手上有写权限令牌，正文没递过来一个 git 命令都不许跑。
@test "claude: without the push guard from the Define step nothing is committed or pushed" {
  push_workspace 'true'
  run_step "$WF" "Verify the Claude fix"
  export FIX_PUSH_GUARD=''

  run run_step "$WF" "Commit and push the Claude fix"

  assert_equal "$status" 1
  assert_contains "$output" 'push guard did not arrive'
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse origin/topic)"
  refute_called 'gh pr comment'
}

# ---------- 轮数标记 M7 ----------

# 推送成功就留一条轮数标记。以前只有 Codex 那半边在推送里发，Claude 这半边在
# Check the fix outcome 里发 —— 同一件事两处各写一份，正是 MEL-262 收掉的东西；
# 现在两条路共用推送那段正文，标记也只有一个来源。少了它这一轮不计数，下一轮
# Gate 从头数，修复轮数上限就永远拦不住。
@test "claude: a pushed round leaves exactly one round marker on the new head" {
  push_workspace 'true'

  run_chain_trusted_push

  assert_equal "$status" 0
  assert_equal "$(step_output pushed)" true
  # 召唤那一步只批这个提交上被扣住的 CI（MEL-292）
  assert_equal "$(step_output head)" "$(git rev-parse HEAD)"
  assert_called 'gh pr comment 7 --repo o/r' 1
  # 正文比全等，顺带守住「标记里不许有触发词」：混进一句 @codex review 就红。
  assert_equal "$(fake_last_body 'gh pr comment')" "🤖 自动修复第 2 轮已推送。

<!-- pr-guard: fix-round head=$(git rev-parse HEAD) round=2 -->"
}

# 标记发不出去（gh 偶发失败，或者它不在写不动的目录里）只警告，不把这一轮判红：
# 推已经成功了，为一条评论打红会让后面召唤复审跟着被跳过，链条反而静默停住。
@test "claude: a round marker that fails to post only warns; the push still stands" {
  push_workspace 'true'
  fake_cli_fail pr_comment 1

  run_chain_trusted_push

  assert_equal "$status" 0
  assert_equal "$(step_output pushed)" true
  assert_contains "$output" 'fix-round marker for'
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse origin/topic)"
}

# ---------- 推不上去：远端的原话归成一个类名交出去 ----------

# 「改好了，但推不上去」以前在 PR 上一个字都没有（2026-10-04 这个仓库自己四条红 run，
# 令牌不许改 workflow 文件）。收尾那一步要据此说清是哪一种拒，所以这一步必须把类名
# 交出来；远端的原话一个字都不往外带 —— 它是远端说的话，照抄进告警就等于让它写告警。
reject_push_with() { # reject_push_with <远端 stderr 的那一行>
  printf '#!/bin/sh\nprintf "%%s\\n" "%s" >&2\nexit 1\n' "$1" \
    >"$BATS_TEST_TMPDIR/origin.git/hooks/pre-receive"
  chmod +x "$BATS_TEST_TMPDIR/origin.git/hooks/pre-receive"
}

@test "claude: a push GitHub refuses over a workflow file comes back as workflow-permission" {
  push_workspace 'true'
  reject_push_with 'refusing to allow a GitHub App to create or update workflow `.github/workflows/ci.yml` without `workflows` permission'

  run_chain_trusted_push

  assert_equal "$status" 1
  assert_equal "$(step_output blocked)" workflow-permission
  assert_contains "$output" 'the push was refused (workflow-permission)'
  # 提交留在本地、远端没动：这一轮确实「改好了但没推上去」
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse refs/heads/topic)"
  [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/topic)" ]
}

@test "claude: a protected branch and a stale branch each get their own class" {
  push_workspace 'true'
  # 两种长相都要认：带 GH006 的，和只有一句大写 Protected branch 的
  for refusal in 'GH006: Protected branch update failed for refs/heads/topic' \
                 'Protected branch update failed for refs/heads/topic'; do
    : >"$GITHUB_OUTPUT"
    reset_workspace
    reject_push_with "$refusal"
    run_chain_trusted_push
    assert_equal "$status" 1
    assert_equal "$(step_output blocked)" protected-branch
  done

  : >"$GITHUB_OUTPUT"
  reset_workspace
  reject_push_with 'hint: Updates were rejected because the tip of your current branch is behind (non-fast-forward)'
  run_chain_trusted_push
  assert_equal "$status" 1
  assert_equal "$(step_output blocked)" non-fast-forward
}

@test "claude: a refusal we do not recognise is still reported, as unknown" {
  push_workspace 'true'
  reject_push_with 'remote: something nobody has seen before'

  run_chain_trusted_push

  assert_equal "$status" 1
  assert_equal "$(step_output blocked)" unknown
  # 原话照旧进日志（排障要它），只是不进告警正文
  assert_contains "$output" 'something nobody has seen before'
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
@test "claude: the summary step filters PATH with the very same block as the push body" {
  pushed="$(fix_guard_body commit_and_push_the_fix | trusted_path_filter)"
  commented="$(trusted_path_block 'Post the Claude summary comment')"
  [ -n "$pushed" ] || { echo 'no PATH filter found in the shared push body' >&2; return 1; }
  assert_equal "$commented" "$pushed"
}

# 跑验证那两步的块里多一行 verify_path="$PATH"（原样那份要留给验证命令自己用），
# 所以整块比不了；能比的是判定本身 —— 十步都得是同一个 path_is_protected。
# 少了这一条，新加一步时照抄漏一行（比如漏掉「相对项不认」那句）没人拦。
@test "claude: all eleven credentialed steps run one and the same path guard" {
  guard=''
  for step in 'Verify the Claude fix' 'Commit and push the Claude fix' \
              'Post the Claude summary comment' 'Check the fix outcome' \
              'Decide the takeover' 'Ask Codex for the fix as a patch' \
              'Verify the Codex fix' 'Commit and push the Codex fix' \
              'Request Codex re-review after a new commit' \
              'Post the Codex verification note' \
              'Say why this round pushed nothing'; do
    this="$(step_path_guard "$step")"
    [ -n "$this" ] || { echo "no PATH filter in: $step" >&2; return 1; }
    if [ -z "$guard" ]; then guard="$this"; continue; fi
    assert_equal "$this" "$guard" || { echo "drifted in: $step" >&2; return 1; }
  done
}

# 上面那段 PATH 过滤是 bash 代码，得先有一个 bash 来跑它。runner 按 PATH 找 bash 的话，
# 验证命令往 ~/.local/bin 放一个假的，下一步的令牌在过滤之前就交出去了（MEL-278）。
@test "claude: every run step in the iterate job starts from an absolute bash, never one found on PATH" {
  job_shell="$(awk '
    $0 == "  iterate:"               { in_job = 1; next }
    in_job && $0 == "    steps:"     { exit }
    in_job && $0 == "    defaults:"  { in_def = 1; next }
    in_def && $0 == "      run:"     { in_run = 1; next }
    in_run && /^        shell: /     { sub(/^        shell: /, ""); print; exit }
  ' "$REPO_ROOT/$WF")"
  assert_equal "$job_shell" "/usr/bin/bash --noprofile --norc -eo pipefail {0}"
  # 单步写 `shell: bash` 会盖掉 job 层那条，同一个洞原样回来。
  overrides="$(awk '
    $0 == "    steps:"                      { in_steps = 1; next }
    in_steps && /^        shell: / && !/^        shell: \// { print NR": "$0 }
  ' "$REPO_ROOT/$WF")"
  assert_equal "$overrides" ""
}

# action 自己的步骤写的是 `shell: bash`，不吃 job 层的默认，照样按 PATH 找 bash。
# 验证命令之后再出现一个 `uses:`，MEL-278 的洞就从那一步回来。只看 iterate 这个 job：
# 别的 job（round-cap-judge）跑在另一台新机器上，被审 PR 的代码在那边一行都没跑过。
@test "claude: no action step runs after the first verify step, where it would find bash on PATH" {
  late_uses="$(awk '
    $0 == "      - name: Verify the Claude fix" { after = 1; next }
    after && /^  [A-Za-z_-]+:$/ { exit }
    after && /^      - uses: |^        uses: / { print NR": "$0 }
  ' "$REPO_ROOT/$WF")"
  assert_equal "$late_uses" ""
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
  # 告警也照跑：以前这一整条链到这里就没人说话了，PR 上一个字都没有（MEL-293）
  gate_ran 'Say why this round pushed nothing'
}

# 推送被拒：同样一个字都没人说过，同样得有人说。
@test "gating: a refused push still reaches the step that explains it" {
  claude_mode_context
  gate_fails 'Commit and push the Claude fix'
  gate_trace "$WF"

  gate_skipped 'Post the Claude summary comment'
  gate_skipped 'Check the fix outcome'
  gate_ran 'Say why this round pushed nothing'
}

# 一轮顺利收工时它不许跑：它只在 job 红了之后补一句为什么。
@test "gating: a green round never reaches the step that explains a failure" {
  claude_mode_context
  gate_trace "$WF"

  gate_ran 'Check the fix outcome'
  gate_skipped 'Say why this round pushed nothing'
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
