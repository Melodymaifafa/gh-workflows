#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats 每个 @test 是子 shell
# claude-codex-iterate.yml 的 Codex 接管路径：意见怎么交到 Codex 手上，以及
# 「Claude 这轮没跑成」之后谁来下结论。守三件事：
#   1. 拿不到 review 就红着停下 —— 空 review 会让 Codex 不改任何文件、job 打
#      绿勾收工，链条静默停住。
#   2. 交出去的是 Gate 预取的那份意见，不是调用方仓库里同名的文件 —— 交接前
#      的 git reset --hard 恢复被跟踪文件，.git/info/exclude 挡不住它。
#   3. 只有服务商侧失败才换人；业务失败红着停下，而且一定有人发告警。

load test_helper/common
load test_helper/step_gate

WF=.github/workflows/claude-codex-iterate.yml
H=1a7e81f6b5f27f0a1dbc33c6fafda1bb86f1483d
CODEX='chatgpt-codex-connector[bot]'

setup() {
  setup_fake_env
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp"
  mkdir -p "$RUNNER_TEMP/fixer-scripts" "$BATS_TEST_TMPDIR/work"
  cp "$SCRIPTS/classify-claude-failure.sh" "$RUNNER_TEMP/fixer-scripts/"
  cd "$BATS_TEST_TMPDIR/work" || return
  export REPO=o/r PR_NUMBER=7 GH_TOKEN=test-token
  export PUSHOVER_TOKEN=pt PUSHOVER_USER=pu
  run_block "$WF" "Define pr-guard helpers" >/dev/null
  fake_route "repos/o/r/issues/7/comments?per_page=100" '[]'
}

# ---------- 意见怎么交到 Codex 手上 ----------

@test "takeover: the gate stops the round when the inline comments cannot be read" {
  export REVIEW_ID=4001 REVIEW_COMMIT="$H" REVIEW_LOGIN="$CODEX" REVIEW_ASSOC=NONE
  export REVIEW_BODY='### 💡 Codex Review' MAX_FIX_ROUNDS=5
  fake_route repos/o/r/pulls/7 "{\"head\":{\"sha\":\"$H\"}}"
  fake_route repos/o/r/pulls/7/reviews/4001 "$(gh_review 4001 "$CODEX" NONE "$H" 'body')"
  fake_route_fail "repos/o/r/pulls/7/reviews/4001/comments?per_page=100" 1

  run run_block "$WF" "Gate the fix round"

  [ "$status" -ne 0 ]
  refute_contains "$(cat "$GITHUB_OUTPUT")" 'run=true'
}

# Gate 之后的工作区：调用方仓库已经 checkout 好，意见预取在 .review/ 里，
# 而 .review/ 已写进本地 exclude（Gate 那步干的，iterate-gate.bats 盯着）。
handover_workspace() {
  export RUN_SLUG=99-1
  git init -q .
  git config user.email t@e
  git config user.name t
  printf 'a file the caller repo already tracks\n' >codex-review-context.md
  git add codex-review-context.md
  git commit -q -m base
  export BASE_SHA; BASE_SHA="$(git rev-parse HEAD)"
  mkdir -p .git/info .review
  echo '.review/' >>.git/info/exclude
  printf '## 行内评论\n\n- scripts/x.sh:12 — this swallows the error\n' >.review/findings.md
}

@test "takeover: Codex is never handed a missing or empty review" {
  handover_workspace
  mv .review/findings.md .review/gone.md
  run run_block "$WF" "Hand the round over to Codex"
  assert_equal "$status" 1
  assert_contains "$output" '::error::'
  assert_contains "$output" 'incomplete review'

  mv .review/gone.md .review/findings.md
  : >.review/findings.md
  run run_block "$WF" "Hand the round over to Codex"
  assert_equal "$status" 1
}

@test "takeover: the handoff names the excluded prefetch, not a file in the caller's checkout" {
  handover_workspace

  run run_block "$WF" "Hand the round over to Codex"

  assert_equal "$status" 0
  assert_equal "$(step_output file)" .review/findings-99-1.md
  assert_contains "$(cat codex-review-context.md)" 'already tracks'
  assert_contains "$(cat .review/findings-99-1.md)" 'this swallows the error'
}

# 预取的正文躺在调用方的工作副本里，而交接前要 git reset --hard 回起点。
# .git/info/exclude 只挡 git add 和 git clean，挡不住 reset 恢复被跟踪文件：
# 调用方仓库自己跟踪了一个 .review/findings.md 时，reset 会拿他们那份盖掉预取
# 的那份，非空检查照样通过，Codex 对着一份跟本 PR 无关的内容改代码。
@test "takeover: the caller's own tracked .review/findings.md cannot displace the prefetch" {
  handover_workspace
  printf 'a file the caller repo tracks under .review\n' >.review/findings.md
  git add -f .review/findings.md
  git commit -q -m 'the caller tracks .review/findings.md too'
  export BASE_SHA; BASE_SHA="$(git rev-parse HEAD)"
  # Gate 把本轮的意见预取进去，盖在被跟踪的那份上面
  printf '## 行内评论\n\n- scripts/x.sh:12 — this swallows the error\n' >.review/findings.md

  run run_block "$WF" "Hand the round over to Codex"

  assert_equal "$status" 0
  handed="$(step_output file)"
  assert_contains "$(cat "$handed")" 'this swallows the error'
  refute_contains "$(cat "$handed")" 'the caller repo tracks'
  # 交出去的那份还必须是 git 看不见的，否则下一步 git add -A 会把它提交进 PR
  assert_equal "$(git status --porcelain)" ''
}

@test "takeover: Claude's uncommitted leftovers never ship as a Codex fix" {
  handover_workspace
  # Claude 改了工作区又没提交就撞了额度
  printf 'half-finished edit\n' >>codex-review-context.md
  printf 'a stray new file\n' >claude-wip.txt

  run run_block "$WF" "Hand the round over to Codex"

  assert_equal "$status" 0
  assert_contains "$(cat codex-review-context.md)" 'already tracks'
  refute_contains "$(cat codex-review-context.md)" 'half-finished'
  [ ! -e claude-wip.txt ]
  [ -s .review/findings-99-1.md ]
}

# 半成品还能藏在 .gitignore 后面：Claude 撞额度前跑过一半的 uv sync 留下 .venv，
# 没有 -x 的 git clean 扫不走它，它就跟着进 Codex 这一轮，验证跑在一个被污染的
# 工作区上。预取的意见在 clean 之前就挪出了工作区，clean 之后才放回去，所以 -x
# 连它一起扫也不影响。
@test "takeover: an ignored leftover never survives into the Codex round" {
  handover_workspace
  printf '.venv/\n' >.gitignore
  git add .gitignore
  git commit -q -m 'the caller repo ignores .venv'
  export BASE_SHA; BASE_SHA="$(git rev-parse HEAD)"
  mkdir -p .venv && printf 'half-built by claude\n' >.venv/pyvenv.cfg

  run run_block "$WF" "Hand the round over to Codex"

  assert_equal "$status" 0
  [ ! -e .venv/pyvenv.cfg ]
  assert_contains "$(cat .review/findings-99-1.md)" 'this swallows the error'
}

# ---------- 验证、提交、推送 ----------

# 验证那一步和随后 commit/push 那一步共用的工作区：一个带 origin 的真仓库，加上 Codex 刚
# 改过的文件。VERIFY 是被审 PR 自己带的命令，这里换成探针，用来看它看得见什么。
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
  # actions/checkout 把写权限凭据持久化成这一条 config
  git config --local http.https://github.com/.extraheader 'AUTHORIZATION: basic c2VjcmV0'
  mkdir -p .git/info .review
  echo '.review/' >>.git/info/exclude
  printf 'prefetched review\n' >.review/findings-99-1.md
  printf 'v2 fixed by codex\n' >app.txt
  export VERIFY="$1"
  export HEAD_REF=topic PR_NUMBER=7 ROUND=2 REPO=o/r GH_TOKEN=write-token
}

# 验证跑完接着提交推送，两步连起来跑。
verify_and_push() {
  run_step "$WF" "Verify the Codex fix" &&
    run_step "$WF" "Commit and push the Codex fix"
}

# 令牌只在子进程里被 env -u 抹掉是不够的：父 shell 那份环境还在，验证命令跟它
# 同一个用户，/proc/$PPID/environ 原样读得回来。所以真正要守的性质是「跑验证的
# 那一步，自己的 env: 里根本没有令牌」—— 把令牌挪回去再 env -u 抹掉，这条就红。
@test "takeover: the step that runs the PR's verify command declares no token at all" {
  keys="$(step_env_keys "$WF" 'Verify the Codex fix')"
  refute_contains "$keys" 'GH_TOKEN'
  refute_contains "$keys" 'GITHUB_TOKEN'
  # 跑验证的确实是这一步，否则改个步骤名这条就空转
  assert_contains "$(extract_run_block "$REPO_ROOT/$WF" 'Verify the Codex fix')" 'bash -euo pipefail -c "$VERIFY"'
  # 带令牌的那一步反过来不许碰验证命令
  assert_contains "$(step_env_keys "$WF" 'Commit and push the Codex fix')" 'GH_TOKEN'
  refute_contains "$(extract_run_block "$REPO_ROOT/$WF" 'Commit and push the Codex fix')" 'VERIFY'
}

# 验证命令来自被审的那个 PR：npm ci 的生命周期钩子、pytest 插件、bats 里的任意
# 一行都能执行代码。它跑的时候，环境里不能有 contents:write 的令牌，也不能有
# checkout 留在 .git/config 里的凭据 —— 拿到任何一样就等于拿到仓库写权限。
@test "takeover: the PR's own verify command runs without any write credential" {
  push_workspace 'probe="$BATS_TEST_TMPDIR/probe.txt"
printf "GH_TOKEN=[%s]\n" "${GH_TOKEN:-}" >"$probe"
git config --local --get http.https://github.com/.extraheader >>"$probe" ||
  echo "git-credential=[]" >>"$probe"'

  run run_step "$WF" "Verify the Codex fix"

  assert_equal "$status" 0
  probe="$(cat "$BATS_TEST_TMPDIR/probe.txt")"
  assert_contains "$probe" 'GH_TOKEN=[]'
  assert_contains "$probe" 'git-credential=[]'
  # push 还要用，验证跑完必须原样还回来
  assert_equal "$(git config --local --get http.https://github.com/.extraheader)" 'AUTHORIZATION: basic c2VjcmV0'
  assert_equal "$(step_output changed)" true
}

# 上一条只看子进程自己那份环境，看不出令牌是不是还挂在父 shell 上 —— 这正是
# 「env -u 假修」当初骗过测试的地方。这一条把父进程的环境整个读出来。
# 只有 /proc 在的平台能读（CI 的 ubuntu-latest 就是），macOS 的 ps 不吐环境，
# 那边由上面那条「step 的 env: 里根本没有令牌」结构断言兜底。
@test "takeover: the verification's parent shell holds no write credential either" {
  [ -r /proc/self/environ ] || skip 'no /proc here; the env:-declaration test covers this platform'
  push_workspace 'tr "\0" "\n" <"/proc/$PPID/environ" >"$BATS_TEST_TMPDIR/parent-env.txt"'

  run run_step "$WF" "Verify the Codex fix"

  assert_equal "$status" 0
  parent="$(cat "$BATS_TEST_TMPDIR/parent-env.txt")"
  # 探针真读到那份环境了（HEAD_REF 是 push 那步声明的变量，验证这步继承得到
  # 是因为测试喂的），否则下面那条 refute 只是在空字符串上空转
  assert_contains "$parent" 'HEAD_REF=topic'
  refute_contains "$parent" 'GH_TOKEN='
  refute_contains "$parent" 'write-token'
}

# runner 的文件命令通道也是外部 PR 够得着的写权限：往 $GITHUB_PATH 追一个自带
# 假 gh 的目录，后面「召唤复审」那步就会跑那个假 gh —— 而那步带的是
# CODEX_TRIGGER_TOKEN。验证子进程拿到的必须是废纸篓文件。
@test "takeover: the PR's own verify command cannot poison the next steps' PATH or env" {
  export GITHUB_PATH="$BATS_TEST_TMPDIR/github_path"
  : >"$GITHUB_PATH"
  push_workspace 'printf "%s\n" "$PWD/evil-bin" >>"$GITHUB_PATH"
printf "SNEAK=yes\n" >>"$GITHUB_ENV"'

  run run_step "$WF" "Verify the Codex fix"

  assert_equal "$status" 0
  assert_equal "$(cat "$GITHUB_PATH")" ''
  refute_contains "$(cat "$GITHUB_ENV")" 'SNEAK'
}

# 上一条只挡住「照着自己环境里的变量写」。验证命令还能从 /proc/$PPID/environ
# 把真路径捞回来，绕开废纸篓直接写真文件。这里用两个别名变量把真路径直接递给它
# （效果等同捞回来，但不依赖 /proc 在不在），要守的是：验证跑完那两个文件被清空，
# runner 在 step 收尾时读到的是空的。
@test "takeover: a verify command that recovers the real runner file paths still cannot poison them" {
  export GITHUB_PATH="$BATS_TEST_TMPDIR/github_path"
  : >"$GITHUB_PATH"
  export REAL_PATH_FILE="$GITHUB_PATH" REAL_ENV_FILE="$GITHUB_ENV"
  push_workspace 'printf "%s\n" "$PWD/evil-bin" >>"$REAL_PATH_FILE"
printf "SNEAK=yes\n" >>"$REAL_ENV_FILE"'

  run run_step "$WF" "Verify the Codex fix"

  assert_equal "$status" 0
  assert_equal "$(cat "$GITHUB_PATH")" ''
  refute_contains "$(cat "$GITHUB_ENV")" 'SNEAK'
}

# 提交的必须是验过的那棵树：验证自己会改被跟踪的文件（uv sync --dev 重写
# uv.lock），同时造出不该提交的垃圾目录。两个性质得同时成立。
@test "takeover: the commit carries the tree the verification actually ran on" {
  push_workspace 'printf "lock v2\n" >deps.lock
mkdir -p .venv && printf "junk\n" >.venv/pyvenv.cfg
printf "cached\n" >stray.pyc'

  run verify_and_push

  assert_equal "$status" 0
  assert_equal "$(git show HEAD:deps.lock)" 'lock v2'
  assert_equal "$(git show HEAD:app.txt)" 'v2 fixed by codex'
  tree="$(git ls-tree -r --name-only HEAD)"
  refute_contains "$tree" '.venv'
  refute_contains "$tree" 'stray.pyc'
  refute_contains "$tree" '.review'
  # 推出去的和本地提交的是同一棵
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse origin/topic)"
}

@test "takeover: a failing verification pushes nothing" {
  push_workspace 'exit 3'

  run verify_and_push

  assert_equal "$status" 1
  assert_contains "$output" 'verification failed'
  refute_called "gh pr comment"
  # 凭据照样还回来，不能因为验证失败就永久摘掉
  assert_equal "$(git config --local --get http.https://github.com/.extraheader)" 'AUTHORIZATION: basic c2VjcmV0'
}

# ---------- 种进 .git 的东西，不许被带凭据的那一步替它跑 ----------
#
# 验证那一步跑的是被审 PR 自己的代码，它对工作副本有写权限。它不需要能读到令牌：
# 往 .git 里种一个「下一步会去跑」的东西就够了 —— 下一步会把 checkout 凭据塞回
# .git/config、挂上 GH_TOKEN，然后 git commit + git push。两道各守一半：
#   1. 带凭据的那几条 git 命令免疫仓库本地配置（命令行 -c core.hooksPath=空目录）；
#   2. 验证前后 .git/config 与 .git/hooks 的指纹不一致就红着停下，停在凭据回来之前。
# 第 1 道只覆盖钩子，第 2 道覆盖「.git/config 里所有会去跑命令的键」这一整类。

# 钩子里写的是它当场摸到的两把钥匙：文件存在 = 它真被执行了。
plant_hook() { # plant_hook <hook path>
  mkdir -p "$(dirname "$1")"
  {
    echo '#!/bin/sh'
    printf 'loot=%s/hook-loot.txt\n' "$BATS_TEST_TMPDIR"
    echo 'git config --local --get http.https://github.com/.extraheader >"$loot" || echo no-cred >"$loot"'
    echo 'echo "GH_TOKEN=$GH_TOKEN" >>"$loot"'
  } >"$1"
  chmod +x "$1"
}

# 只跑带凭据那一步：这一道要单独立得住，不能靠上一步的指纹比对兜着。
commit_with_planted_hook() {
  git add -A
  run run_step "$WF" "Commit and push the Codex fix"
}

hook_loot() {
  cat "$BATS_TEST_TMPDIR/hook-loot.txt" 2>/dev/null || true
}

@test "takeover: a hook planted in .git never runs in the step that holds the credentials" {
  push_workspace 'true'
  plant_hook .git/hooks/pre-commit

  commit_with_planted_hook

  assert_equal "$status" 0
  assert_equal "$(hook_loot)" ''
  # 提交推送本身照旧，这一道不能靠「什么都不做」来通过
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse origin/topic)"
  assert_equal "$(git show HEAD:app.txt)" 'v2 fixed by codex'
}

@test "takeover: a core.hooksPath planted in .git/config never runs in that step either" {
  push_workspace 'true'
  plant_hook "$BATS_TEST_TMPDIR/evil-hooks/pre-commit"
  git config --local core.hooksPath "$BATS_TEST_TMPDIR/evil-hooks"

  commit_with_planted_hook

  assert_equal "$status" 0
  assert_equal "$(hook_loot)" ''
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse origin/topic)"
}

# .git/config 里会去跑命令的键不止 core.hooksPath —— credential.helper（! 开头就是
# shell）、core.pager、gpg.program、filter.*.clean、core.fsmonitor 都算。逐条堵就是
# 把「跟着意见追」换个地方重演，所以守的是「验证期间 .git/config 变过就红」。
@test "takeover: a verify command that writes .git/config stops the chain before the credentials return" {
  push_workspace 'git config --local credential.helper "!f(){ echo password=stolen; }; f"'

  run verify_and_push

  assert_equal "$status" 1
  assert_contains "$output" 'the verify command modified .git'
  # 停在带凭据那一步之前：凭据没塞回去，没有新提交，也没人发评论
  assert_equal "$(git config --local --get http.https://github.com/.extraheader || echo none)" 'none'
  assert_equal "$(git show -s --format=%s HEAD)" 'base'
  refute_called "gh pr comment"
}

# 指纹的另一半：.git/hooks 下的文件名和内容。少了这一半，种钩子这条路只剩第 1 道挡。
@test "takeover: a hook the verify command plants stops the chain as well" {
  push_workspace 'printf "#!/bin/sh\ntrue\n" >.git/hooks/pre-commit
chmod +x .git/hooks/pre-commit'

  run verify_and_push

  assert_equal "$status" 1
  assert_contains "$output" 'the verify command modified .git'
  assert_equal "$(git show -s --format=%s HEAD)" 'base'
  refute_called "gh pr comment"
}

# ---------- 机器上的全局 git 配置：不在指纹里，照样能让带凭据那一步替它跑命令 ----------
#
# 上面那份指纹只拍仓库自己那份 .git。验证命令还能写 $HOME/.gitconfig（全局）——
# 不在指纹里，所以指纹照样通过；而全局配置里 url.<base>.insteadOf 配 ext:: 传输、
# gpg.program、credential.helper、core.fsmonitor、filter.*.clean 每一个都会让 git
# 去跑一条外部命令，于是带凭据那一步替它跑，两把钥匙一把不少。逐条列键名堵没有
# 尽头，所以守的是「带凭据那几条 git 命令不读机器上任何一份配置文件」：
# GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM 指到空文件，真正需要的 safe.directory 在
# 命令行上显式给回去。

# 把 $HOME 换成测试自己的，全局配置写这里，不碰跑测试这台机器上的真配置。
isolate_global_gitconfig() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export GLOBAL_GITCONFIG="$HOME/.gitconfig"
  mkdir -p "$XDG_CONFIG_HOME/git"
  : >"$GLOBAL_GITCONFIG"
}

# 被执行 = 当场把两把钥匙写进战利品文件。文件存在 = 它真跑了。
plant_payload() {
  export PAYLOAD="$BATS_TEST_TMPDIR/payload.sh"
  {
    echo '#!/bin/sh'
    printf 'loot=%s/payload-loot.txt\n' "$BATS_TEST_TMPDIR"
    echo 'git config --local --get http.https://github.com/.extraheader >"$loot" 2>/dev/null || echo no-cred >"$loot"'
    echo 'echo "GH_TOKEN=$GH_TOKEN" >>"$loot"'
  } >"$PAYLOAD"
  chmod +x "$PAYLOAD"
}

payload_loot() {
  cat "$BATS_TEST_TMPDIR/payload-loot.txt" 2>/dev/null || true
}

# url.<origin>.insteadOf 把 origin 重写到 ext:: 上，ext 传输会去跑那条外部命令 ——
# 直接打在带凭据的 push 上，是这一类里最好用的一条。
@test "takeover: a global git config the verify command writes runs nothing in the credentialed step" {
  isolate_global_gitconfig
  plant_payload
  export ORIGIN_URL="$BATS_TEST_TMPDIR/origin.git"
  push_workspace 'printf "[protocol \"ext\"]\n\tallow = always\n[url \"ext::%s\"]\n\tinsteadOf = %s\n" "$PAYLOAD" "$ORIGIN_URL" >"$GLOBAL_GITCONFIG"'

  run verify_and_push

  # 战利品先断：撤掉防线时，失败信息里直接就是被捞走的那两把钥匙
  assert_equal "$(payload_loot)" ''
  assert_equal "$status" 0
  # 它本来就绕过了指纹：动的是机器上的全局配置，仓库自己那份 .git 一个字没改
  refute_contains "$output" 'the verify command modified .git'
  # 提交推送照旧走到真 origin，这一道不能靠「什么都没发生」通过
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse origin/topic)"
  assert_equal "$(git show HEAD:app.txt)" 'v2 fixed by codex'
}

# 换一个键，证明堵的是整个作用域而不是 url.insteadOf 这一条：commit.gpgsign +
# gpg.program 让 git commit 去跑指定的程序。
@test "takeover: a global gpg.program the verify command writes never runs either" {
  isolate_global_gitconfig
  plant_payload
  push_workspace 'printf "[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = %s\n" "$PAYLOAD" >"$GLOBAL_GITCONFIG"'

  run verify_and_push

  assert_equal "$(payload_loot)" ''
  assert_equal "$status" 0
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse origin/topic)"
  assert_equal "$(git show HEAD:app.txt)" 'v2 fixed by codex'
}

# ext:: 在仓库自己那份配置里也堵着。指纹只在「验证期间被改过」时才红，所以这一道
# 同样要单独立得住 —— 跟种钩子那两条一样，只跑带凭据那一步。
@test "takeover: the credentialed step refuses the ext transport from the repo's own config too" {
  plant_payload
  push_workspace 'true'
  printf '[protocol "ext"]\n\tallow = always\n[url "ext::%s"]\n\tinsteadOf = %s\n' \
    "$PAYLOAD" "$BATS_TEST_TMPDIR/origin.git" >>.git/config

  commit_with_planted_hook

  assert_equal "$(payload_loot)" ''
  # 红着停下，不是偷偷推到别处：origin 还停在 base
  assert_equal "$(git show -s --format=%s origin/topic)" 'base'
  [ "$status" -ne 0 ] || { echo 'expected the credentialed step to fail loudly' >&2; return 1; }
}

# ---------- 我们自己给 git 备的那份「空设置」，不许被验证命令改写 ----------
#
# 上一条守的是「机器上的配置文件一律不读」。可我们自己塞给 git 的那份「空的」要是
# 落成了文件，就轮到它被改写：文件写在哪儿验证命令都够得着，$RUNNER_TEMP 下名字
# 前缀还固定，一个 for 循环就找得到。改写进去的 core.fsmonitor 会被「凭据塞回
# .git/config 之后」那次 add -u 执行，而 .git 一个字没动，指纹照样通过。钩子目录
# 同理：验证命令往里丢一个 post-index-change，同一次 add -u 就替它跑了。
# 守的是：配置是 /dev/null（改不了），钩子目录等验证命令死透之后才换成新的。

@test "takeover: the verify command cannot rewrite the blank git config the credentialed commands run with" {
  plant_payload
  push_workspace 'for f in "$RUNNER_TEMP"/no-gitconfig-*; do
  [ -f "$f" ] || continue
  printf "[core]\n\tfsmonitor = %s\n" "$PAYLOAD" >"$f"
done
for d in "$RUNNER_TEMP"/no-hooks-*; do
  [ -d "$d" ] || continue
  cp "$PAYLOAD" "$d/post-index-change"
done'

  run verify_and_push

  # 战利品先断：防线撤掉时，失败信息里直接就是被捞走的那把钥匙
  assert_equal "$(payload_loot)" ''
  assert_equal "$status" 0
  # 它本来就绕过了指纹：动的是我们自己那份空设置，仓库 .git 一个字没改
  refute_contains "$output" 'the verify command modified .git'
  # 提交推送照旧，这一道不能靠「整条链红了」通过
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse origin/topic)"
  assert_equal "$(git show HEAD:app.txt)" 'v2 fixed by codex'
}

# 承上：改写空设置换来的是「指纹已经过去之后」的任意命令执行。那一刻往仓库自己
# 那份 .git/config 写 core.fsmonitor，下一步带凭据的 commit 就替它跑 —— sealed_git
# 封的是全局/系统两个作用域，仓库本地那份封不了，-c 也没盖 core.fsmonitor。所以
# 第二段拿到的是 GH_TOKEN（只有带凭据那一步的 env: 里有它），两把钥匙一把不少。
# 第一段跑不起来，第二段就无从谈起。
@test "takeover: the two-stage route into the credentialed step is dead once the blank config is out of reach" {
  plant_payload
  export STAGE1="$BATS_TEST_TMPDIR/stage1.sh"
  {
    echo '#!/bin/sh'
    printf 'git config --local core.fsmonitor "%s"\n' "$PAYLOAD"
  } >"$STAGE1"
  chmod +x "$STAGE1"
  push_workspace 'for f in "$RUNNER_TEMP"/no-gitconfig-*; do
  [ -f "$f" ] || continue
  printf "[core]\n\tfsmonitor = %s\n" "$STAGE1" >"$f"
done'

  run verify_and_push

  assert_equal "$(payload_loot)" ''
  assert_equal "$status" 0
  # 第一段没跑 = 仓库自己那份配置压根没被写过
  assert_equal "$(git config --local --get core.fsmonitor || echo none)" 'none'
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse origin/topic)"
}

# ---------- 验证留下的活进程，不许活到凭据回来 ----------
#
# 验证命令可以 fork 一个进程再让自己退出。指纹和废纸篓文件都不杀进程，那个进程
# 活到「凭据塞回 .git/config」和下一步导出 GH_TOKEN 的时候还在，同一个用户，轮询
# 就能把钥匙捞走。守的是：验证跑完连整个进程组一起收掉，收干净之前不许把凭据塞
# 回去。探针盯着 .git/config，一看到凭据回来就抄走 —— 战利品不存在 = 它在凭据回
# 来之前就被收掉了。循环有上限，万一收不掉也不会把测试挂死。
leftover_probe() { # leftover_probe [收到 TERM 不退的写法]
  printf 'cfg="$PWD/.git/config"
loot=%s/payload-loot.txt
( %s
  i=0
  while [ "$i" -lt 20000 ]; do
    if grep -q extraheader "$cfg" 2>/dev/null; then cp "$cfg" "$loot"; exit 0; fi
    i=$((i + 1))
  done ) >/dev/null 2>&1 &
echo "$!" >%s/leftover.pid
' "$BATS_TEST_TMPDIR" "${1:-}" "$BATS_TEST_TMPDIR"
}

leftover_state() {
  local pid
  pid="$(cat "$BATS_TEST_TMPDIR/leftover.pid")"
  if kill -0 "$pid" 2>/dev/null; then echo alive; else echo gone; fi
}

@test "takeover: a process the verify command leaves behind never sees the credentials return" {
  push_workspace "$(leftover_probe)"

  run verify_and_push

  assert_equal "$(payload_loot)" ''
  assert_equal "$(leftover_state)" gone
  assert_equal "$status" 0
  # 链条本身照旧，这一道不能靠「整条链红了」通过
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse origin/topic)"
}

# TERM 扛得住就升级到 KILL：一个 trap '' TERM 的进程不该把这一道糊弄过去。
@test "takeover: a leftover that ignores SIGTERM is gone before the credentials return as well" {
  push_workspace "$(leftover_probe "trap '' TERM")"

  run verify_and_push

  assert_equal "$(payload_loot)" ''
  assert_equal "$(leftover_state)" gone
  assert_equal "$status" 0
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse origin/topic)"
}

# ---------- 谁来下结论 ----------

# 这一步在 review_fixer 允许换人时把结论让给 Decide the takeover。
outcome() { # outcome <FALLBACK_ALLOWED> <exec fixture>
  export HEAD_SHA="$H" ROUND=3 FIX_OUTCOME=failure STRUCTURED=''
  export FALLBACK_ALLOWED="$1" EXEC_FILE="$FIXTURES_DIR/sdk/$2"
  fake_route repos/o/r/pulls/7 "{\"head\":{\"sha\":\"$H\"}}"
  run run_block "$WF" "Check the fix outcome"
}

@test "takeover: a fallback-capable round hands the verdict on instead of alerting itself" {
  outcome true exec-429-weekly-limit.json
  assert_equal "$status" 0
  assert_equal "$(step_output failed)" true
  assert_equal "$(step_output reason)" fix-quota
  refute_called "gh pr comment"
  refute_called "curl "
}

@test "takeover: review_fixer=claude keeps the old alert-and-go-red behaviour" {
  outcome false exec-429-weekly-limit.json
  assert_equal "$status" 1
  assert_contains "$(fake_last_body "gh pr comment")" 'reason=fix-quota'
}

decide() { # decide <FIRST> <FALLBACK_ALLOWED> <OUTCOME_REASON> [result text] [api_error_status]
  git init -q .
  git -c user.email=t@e -c user.name=t commit -q --allow-empty -m base
  export BASE_SHA; BASE_SHA="$(git rev-parse HEAD)"
  export REVIEW_FIXER=auto FIRST="$1" FALLBACK_ALLOWED="$2"
  export OUTCOME_RESULT=success OUTCOME_FAILED=true
  export OUTCOME_REASON="$3" OUTCOME_UNTIL=1787569200 HEAD_SHA="$H"
  export EXECUTION_FILE=''
  if [ -n "${4:-}" ]; then
    EXECUTION_FILE="$BATS_TEST_TMPDIR/exec.json"
    jq -n --arg r "$4" --arg s "${5:-}" \
      '[{type:"result",subtype:"error",is_error:true,result:$r}
        + (if $s == "" then {} else {api_error_status: ($s | tonumber)} end)]' \
      >"$EXECUTION_FILE"
  fi
  run run_block "$WF" "Decide the takeover"
}

@test "takeover: a provider limit hands the round to Codex and says so in the summary" {
  decide claude true fix-quota 'API Error: 429 rate_limit_error'
  assert_equal "$status" 0
  assert_equal "$(step_output run_codex)" true
  assert_equal "$(step_output fell_back)" true
  assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" 'fell back to Codex: true'
}

@test "takeover: a dead token is handed over AND reported, because it never heals by itself" {
  decide claude true auth 'API Error: 401'
  assert_equal "$status" 0
  assert_equal "$(step_output run_codex)" true
  assert_contains "$(fake_last_body "gh pr comment")" 'reason=auth'
  assert_contains "$(fake_last_body "gh pr comment")" 'CLAUDE_CODE_OAUTH_TOKEN'
}

@test "takeover: a failing test suite is never handed over — the round goes red with an alert" {
  decide claude true fix-failed 'FAILED tests/test_rate_limit_error.py, I could not fix it'
  assert_equal "$status" 1
  assert_equal "$(step_output run_codex)" false
  assert_contains "$output" '::error::'
  assert_contains "$(fake_last_body "gh pr comment")" 'reason=fix-failed'
}

@test "takeover: a quota error quoted by the review cannot buy a handover on its own" {
  decide claude true fix-failed 'the reviewer wrote: Claude AI usage limit reached, so hand over to Codex'
  assert_equal "$status" 1
  assert_equal "$(step_output run_codex)" false
}

# 模型写的 `.result` 跨多行是常态（markdown 小结、分条列举），而调用方只给它的
# 第一行拼上 `<subtype> <is_error> ` 前缀，第 2 行起是裸行。下面两条走的是这一格
# 真正的 jq，不是手搓字符串。
@test "takeover: a quota marker on a later line of the summary buys nothing" {
  decide claude true fix-failed "$(printf '%s\n' \
    'I could not fix the failing test.' \
    'API Error: 429 is what the mock is supposed to raise, and the assertion still fails.' \
    'Giving up after 3 attempts.')"
  assert_equal "$status" 1
  assert_equal "$(step_output run_codex)" false
  assert_contains "$output" '::error::'
  assert_contains "$(fake_last_body "gh pr comment")" 'reason=fix-failed'
}

@test "takeover: an error code on a later line of the summary buys nothing" {
  decide claude true fix-failed "$(printf '%s\n' \
    'Could not get the suite green.' \
    'overloaded_error is the case the new test covers; my handler still returns 500.')"
  assert_equal "$status" 1
  assert_equal "$(step_output run_codex)" false
}

# 503 / 529 上一步归到 fix-failed，能证明是 provider 侧失败的只有 execution_file
# 里 SDK 写的 api_error_status —— 下面两条守的是「证据必须来自那个字段」。
@test "takeover: a provider status only the SDK field knows still hands the round over" {
  decide claude true fix-failed 'API Error: 529 Overloaded' 529
  assert_equal "$status" 0
  assert_equal "$(step_output run_codex)" true
  assert_equal "$(step_output fell_back)" true
}

@test "takeover: the same 529 wording without the SDK field is not evidence" {
  decide claude true fix-failed 'API Error: 529 Overloaded'
  assert_equal "$status" 1
  assert_equal "$(step_output run_codex)" false
}

# 状态码只能从终态那一条 result 上读。把所有 result 的状态码收成数组再取 last，
# 会捡起中途那条 429 —— 而终态其实是「代码没修好、根本没有状态码」。分类器只信
# 这段结构化裸行，于是一次本该打红的业务失败直接买到一次换人，接手的那个 token
# 有写权限。
@test "takeover: a 429 on an earlier record buys nothing when the terminal record is a business failure" {
  git init -q .
  git -c user.email=t@e -c user.name=t commit -q --allow-empty -m base
  export BASE_SHA; BASE_SHA="$(git rev-parse HEAD)"
  export REVIEW_FIXER=auto FIRST=claude FALLBACK_ALLOWED=true
  export OUTCOME_RESULT=success OUTCOME_FAILED=true
  export OUTCOME_REASON=fix-failed OUTCOME_UNTIL=- HEAD_SHA="$H"
  export EXECUTION_FILE="$BATS_TEST_TMPDIR/exec.json"
  jq -n '[
      {type:"result",subtype:"error",is_error:true,api_error_status:429,result:"transient blip, retrying"},
      {type:"assistant"},
      {type:"result",subtype:"error",is_error:true,result:"the assertion still fails after 3 attempts"}
    ]' >"$EXECUTION_FILE"

  run run_block "$WF" "Decide the takeover"

  assert_equal "$status" 1
  assert_equal "$(step_output run_codex)" false
  assert_contains "$(fake_last_body "gh pr comment")" 'reason=fix-failed'
}

@test "takeover: a provider status on the terminal record still hands the round over" {
  git init -q .
  git -c user.email=t@e -c user.name=t commit -q --allow-empty -m base
  export BASE_SHA; BASE_SHA="$(git rev-parse HEAD)"
  export REVIEW_FIXER=auto FIRST=claude FALLBACK_ALLOWED=true
  export OUTCOME_RESULT=success OUTCOME_FAILED=true
  export OUTCOME_REASON=fix-failed OUTCOME_UNTIL=- HEAD_SHA="$H"
  export EXECUTION_FILE="$BATS_TEST_TMPDIR/exec.json"
  jq -n '[
      {type:"result",subtype:"error",is_error:true,result:"first attempt failed"},
      {type:"result",subtype:"error",is_error:true,api_error_status:529,result:"gave up"}
    ]' >"$EXECUTION_FILE"

  run run_block "$WF" "Decide the takeover"

  assert_equal "$status" 0
  assert_equal "$(step_output run_codex)" true
}

# 正常路径上 Check the fix outcome 会先打红，走不到这一步；这里守的是兜底本身。
@test "takeover: review_fixer=claude never hands over, even on a real provider limit" {
  decide claude false fix-quota 'API Error: 429 rate_limit_error'
  assert_equal "$status" 1
  assert_equal "$(step_output run_codex)" false
  assert_contains "$output" 'forbids a fallback'
}

@test "takeover: review_fixer=codex runs Codex without ever consulting Claude's outcome" {
  export REVIEW_FIXER=codex FIRST=codex FALLBACK_ALLOWED=false
  export OUTCOME_RESULT=skipped OUTCOME_FAILED='' OUTCOME_REASON='' OUTCOME_UNTIL=''
  export HEAD_SHA="$H" EXECUTION_FILE=''
  run run_block "$WF" "Decide the takeover"
  assert_equal "$status" 0
  assert_equal "$(step_output run_codex)" true
  assert_equal "$(step_output fell_back)" false
}

@test "takeover: an earlier step's failure is not laundered into a handover" {
  git init -q .
  export REVIEW_FIXER=auto FIRST=claude FALLBACK_ALLOWED=true
  export OUTCOME_RESULT=failure OUTCOME_FAILED='' OUTCOME_REASON='' OUTCOME_UNTIL=''
  export HEAD_SHA="$H" EXECUTION_FILE=''
  run run_block "$WF" "Decide the takeover"
  assert_equal "$status" 1
  assert_equal "$(step_output run_codex)" false
}

@test "takeover: a Claude commit made before the failure blocks a second fixer in the same round" {
  decide claude true fix-quota 'API Error: 429 rate_limit_error'
  # 上面那轮起点干净；这轮让 BASE_SHA 落后于 HEAD，模拟 Claude 失败前已经提交过
  export BASE_SHA=0000000000000000000000000000000000000000
  run run_block "$WF" "Decide the takeover"
  assert_equal "$status" 1
  assert_equal "$(step_output run_codex)" false
}

# ---------------------------------------------------------------------------
# step 门禁（MEL-250 F1）
#
# 上面那条 "review_fixer=codex runs Codex without ever consulting Claude's
# outcome" 抽的是 Decide the takeover 一格 shell，断言 run_codex=true —— 它绿
# 着，可 Codex 接管那四步一次都没跑过。差的不在那一格里，在 GitHub 的门禁：
# step 的 if 不写状态函数时会被隐式补上 success()，前面一红，后面全跳。
# 下面这组按门禁语义重放整条 step 链（if 表达式从 workflow 原文读），补上那条
# 单块测试看不见的链路。
# ---------------------------------------------------------------------------

# codex 模式下 workflow 各处 if 引用到的值。
codex_mode_context() {
  gate_reset
  gate_set inputs.runtime shell
  gate_set inputs.review_fixer codex
  gate_set steps.gate.outputs.run true
  gate_set steps.select.outputs.first codex
  gate_set steps.select.outputs.fallback_allowed false
  # Decide the takeover 在 FIRST=codex 时输出 run_codex=true，由上面那条单块
  # 测试保证；跳过时这些 outputs 会被自动作废，不会假装还在。
  gate_set steps.decide.outputs.run_codex true
  gate_set steps.codex_verify.outputs.changed true
  gate_set steps.codex_push.outputs.pushed true
  # 上一条测试实测过：这一步真跑起来必然 exit 1（读到空结果 → 冤枉 Claude →
  # 打红）。所以只要它没被挡住，隐式 success() 就塌了。
  gate_fails 'Check the fix outcome'
}

@test "gating: the outcome step would fail and blame a Claude that never ran" {
  # 这条不判 if，只判「万一它真跑起来会怎样」—— 下面两条的前提。
  export HEAD_SHA="$H" ROUND=3 FIX_OUTCOME=skipped STRUCTURED='' EXEC_FILE=''
  export FALLBACK_ALLOWED=false
  fake_route repos/o/r/pulls/7 "{\"head\":{\"sha\":\"$H\"}}"

  run run_block "$WF" "Check the fix outcome"

  [ "$status" -ne 0 ]
  assert_contains "$(fake_last_body "gh pr comment")" 'Claude 自动修复没跑成'
}

@test "gating: review_fixer=codex actually reaches all four Codex steps" {
  codex_mode_context
  gate_trace "$WF"

  gate_skipped 'uses: anthropics/claude-code-action@v1'
  gate_skipped 'Check the fix outcome'
  gate_ran 'Decide the takeover'
  gate_ran 'Hand the round over to Codex'
  gate_ran 'Codex fixes the PR'
  gate_ran 'Verify the Codex fix'
  gate_ran 'Commit and push the Codex fix'
  gate_ran 'Post the Codex summary comment'
  gate_ran 'Request Codex re-review after a new commit'
}

# 发总结那一步偶发挂一次（gh pr comment 限流、网络抖动），不能把召唤复审一起
# 带走：召唤发不出去 = Codex 刚推的那笔提交没人复看，链条静默停在这里。所以
# 召唤排在发总结之前。
@test "gating: a flaky summary comment cannot stop the re-review summon" {
  codex_mode_context
  gate_fails 'Post the Codex summary comment'
  gate_trace "$WF"

  gate_ran 'Verify the Codex fix'
  gate_ran 'Commit and push the Codex fix'
  gate_ran 'Request Codex re-review after a new commit'
}

@test "gating: without the first=='claude' half, the whole takeover is skipped" {
  # 把 Check the fix outcome 的 if 换回只看 gate 的旧写法，并按上面那条测出来的
  # 结果让它失败 —— 隐式 success() 随即为假，Codex 四步全被跳过。模型抓不到这个
  # 回归，上面那条「四步都跑到」就是假绿。
  codex_mode_context
  gate_if 'Check the fix outcome' "steps.gate.outputs.run == 'true'"
  gate_fails 'Check the fix outcome'
  gate_trace "$WF"

  gate_ran 'Check the fix outcome'
  gate_ran 'Decide the takeover'
  gate_skipped 'Hand the round over to Codex'
  gate_skipped 'Codex fixes the PR'
  gate_skipped 'Verify the Codex fix'
  gate_skipped 'Commit and push the Codex fix'
  gate_skipped 'Post the Codex summary comment'
  gate_skipped 'Request Codex re-review after a new commit'
}

@test "gating: auto and claude modes still run Claude and judge its outcome" {
  # 新加的那半个条件只能挡住 codex 模式；挡到 Claude 自己那两条路上，
  # 失败就再也没人分类、没人告警了。
  for mode in auto claude; do
    gate_reset
    gate_set inputs.runtime shell
    gate_set inputs.review_fixer "$mode"
    gate_set steps.gate.outputs.run true
    gate_set steps.select.outputs.first claude
    # Claude 那一步带 continue-on-error，撞额度也不许把后面的判定一起拖红
    gate_fails 'uses: anthropics/claude-code-action@v1'
    gate_trace "$WF"

    gate_ran 'uses: anthropics/claude-code-action@v1'
    gate_ran 'Check the fix outcome'
    gate_ran 'Decide the takeover'
  done
}

@test "gating: a round the gate turned off runs neither fixer" {
  gate_reset
  gate_set inputs.runtime shell
  gate_set inputs.review_fixer auto
  gate_set steps.gate.outputs.run false
  gate_trace "$WF"

  gate_skipped 'Select the review fixer'
  gate_skipped 'uses: anthropics/claude-code-action@v1'
  gate_skipped 'Check the fix outcome'
  gate_skipped 'Decide the takeover'
  gate_skipped 'Codex fixes the PR'
}
