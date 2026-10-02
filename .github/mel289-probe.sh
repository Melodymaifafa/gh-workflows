#!/usr/bin/env bash
# MEL-289 的一次性探针（只活在探针分支上，不进 PR）。
# 按生产顺序把四步在真 runner 上跑一遍：Resolve runtime defaults → Define the fix
# verify and push guards → Verify the Claude fix → Commit and push the Claude fix。
# 第二轮把 /proc 重新挂成 hidepid=2 —— 那正是复审点名的那种机器：普通身份看不见别人
# 的进程，而「看不见」是清点的放行条件。
set -uo pipefail

WF=.github/workflows/claude-codex-iterate.yml
SRC="$PWD"
say() { printf '\n========== %s ==========\n' "$*"; }

extract_run_block() {
  awk -v want="      - name: $1" '
    $0 == want { in_step = 1; next }
    in_step && !in_run && $0 == "        run: |" { in_run = 1; next }
    in_run {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      if ($0 !~ /^          /)   { exit }
      sub(/^          /, "")
      print
    }
  ' "$SRC/$WF"
}

run_block() {
  local f
  f="$(mktemp "$RUNNER_TEMP/block-XXXXXX.sh")"
  extract_run_block "$1" >"$f"
  [ -s "$f" ] || { echo "probe: no run block for '$1'" >&2; return 98; }
  bash --noprofile --norc -eo pipefail "$f"
}

step_output() {
  awk -v want="$1" '
    delim != "" {
      if ($0 == delim) { if (name == want) { val = buf; found = 1 }; delim = ""; next }
      buf = (started ? buf "\n" : "") $0; started = 1; next
    }
    match($0, /^[A-Za-z_][A-Za-z0-9_-]*<</) {
      name = substr($0, 1, RLENGTH - 2); delim = substr($0, RLENGTH + 1); buf = ""; started = 0; next
    }
    index($0, want "=") == 1 { val = substr($0, length(want) + 2); found = 1 }
    END { if (found) print val; else exit 1 }
  ' "$GITHUB_OUTPUT"
}

export GITHUB_OUTPUT="$RUNNER_TEMP/probe-output"
export GITHUB_ENV="$RUNNER_TEMP/probe-env"
export GITHUB_STEP_SUMMARY="$RUNNER_TEMP/probe-summary"
: >"$GITHUB_OUTPUT"; : >"$GITHUB_ENV"; : >"$GITHUB_STEP_SUMMARY"

# ---------- 第 1 步：Resolve runtime defaults ----------
say 'step 1/4  Resolve runtime defaults'
RUNTIME=shell VERIFY_OVERRIDE='' CLAUDE_MODEL=claude-opus-5-5 CLAUDE_EFFORT=xhigh \
  VERIFY_ISOLATION=auto run_block 'Resolve runtime defaults' || exit 1
VERIFY_CMD="$(awk '/^VERIFY_CMD<<__GHA_EOF__$/{f=1;next} f&&/^__GHA_EOF__$/{exit} f' "$GITHUB_ENV")"
printf 'resolved verify command:\n%s\n' "$VERIFY_CMD"
[ -n "$VERIFY_CMD" ] || exit 1

# ---------- 第 2 步：Define the fix verify and push guards ----------
say 'step 2/4  Define the fix verify and push guards'
: >"$GITHUB_OUTPUT"
run_block 'Define the fix verify and push guards' || exit 1
FIX_VERIFY_GUARD="$(step_output verify)" || exit 1
FIX_PUSH_GUARD="$(step_output push)" || exit 1
printf 'verify guard: %s lines; push guard: %s lines\n' \
  "$(printf '%s\n' "$FIX_VERIFY_GUARD" | wc -l)" "$(printf '%s\n' "$FIX_PUSH_GUARD" | wc -l)"
export FIX_VERIFY_GUARD FIX_PUSH_GUARD

# ---------- 工作区：本仓库自己的一份副本，带一个本地 bare origin ----------
# 位置照生产的样子放在 $RUNNER_TEMP 下（/home/runner 那一级是 0750 runner:runner，
# 专用账号要靠加进 runner 组才进得去 —— 正是生产路径上的那一步）。
make_workspace() {
  WS="$(mktemp -d "$RUNNER_TEMP/probe-ws-XXXXXX")"
  # 0711：mktemp 给的是 0700，专用账号连 cd 都进不去（生产路径上 $GITHUB_WORKSPACE
  # 的上一级是 0750 runner:runner，账号靠加进 runner 组进去，这里对齐那个形状）。
  chmod 0711 "$WS"
  mkdir -p "$WS/ws"
  git -C "$SRC" archive HEAD | tar -x -C "$WS/ws"
  cd "$WS/ws" || return 1
  git init -q -b topic .
  git config user.email probe@example.com
  git config user.name probe
  git add -A
  git commit -q -m base
  git init -q --bare "$WS/origin.git"
  git remote add origin "$WS/origin.git"
  git push -q origin HEAD:topic
  # actions/checkout 的老样子：凭据写进 .git/config。验证那一步必须把它摘掉。
  git config --local http.https://github.com/.extraheader 'AUTHORIZATION: basic cHJvYmU='
  # 「fixer 刚改过的文件」——真正的 fixer（Claude 的 action）这一票一个字没碰
  printf '\n<!-- probe: the fixer touched this -->\n' >>README.md
}

run_verify_and_push() { # run_verify_and_push <轮次标签>
  : >"$GITHUB_OUTPUT"; : >"$GITHUB_ENV"
  say "step 3/4  Verify the Claude fix  ($1)"
  FIXER=Claude VERIFY="$VERIFY_CMD" VERIFY_WRITABLE_PATHS='' VERIFY_ISOLATION=auto \
    run_block 'Verify the Claude fix'
  verify_status=$?
  printf 'verify exit=%s  changed=%s\n' "$verify_status" "$(step_output changed 2>/dev/null || echo '<none>')"
  [ "$verify_status" -eq 0 ] || return "$verify_status"
  say "step 4/4  Commit and push the Claude fix  ($1)"
  FIXER=Claude REPO=o/r ROUND=2 HEAD_REF=topic PR_NUMBER=7 GH_TOKEN=probe-token \
    run_block 'Commit and push the Claude fix'
  push_status=$?
  printf 'push exit=%s\n' "$push_status"
  return "$push_status"
}

evidence() { # evidence <轮次标签>
  say "evidence  ($1)"
  printf 'the verify command reported it ran as: %s\n' "$(cat ran-as.txt 2>/dev/null || echo '<no marker>')"
  printf 'reading our environ from there:       %s\n' "$(cat environ-verdict.txt 2>/dev/null || echo '<no marker>')"
  printf 'sudo from there:                      %s\n' "$(cat sudo-verdict.txt 2>/dev/null || echo '<no marker>')"
  printf 'cron.deny: [%s]\n' "$(sudo -n grep -c . /etc/cron.deny 2>/dev/null || echo unreadable) lines, ghwf-verify listed: $(sudo -n grep -qxF ghwf-verify /etc/cron.deny 2>/dev/null && echo yes || echo no)"
  printf 'at.deny:   [%s]\n' "$(sudo -n grep -c . /etc/at.deny 2>/dev/null || echo unreadable) lines, ghwf-verify listed: $(sudo -n grep -qxF ghwf-verify /etc/at.deny 2>/dev/null && echo yes || echo no)"
  printf 'live processes under the account now: [%s]\n' "$(sudo -n ps -U ghwf-verify -o pid=,args= 2>/dev/null | tr '\n' ';')"
  printf 'account still in the workspace group: %s\n' "$(id -nG ghwf-verify 2>/dev/null || echo '<no account>')"
  printf 'the pushed tree carries the fix:      %s\n' "$(git show origin/topic:README.md 2>/dev/null | tail -n 1)"
  printf 'step summary:\n%s\n' "$(cat "$GITHUB_STEP_SUMMARY" 2>/dev/null)"
}

# 验证命令 = 本仓库生产用的那三条，外加几个只报信的探针
# shellcheck disable=SC2016  # 这几行是递给验证命令的脚本文本，就该原样不展开
PROBE_MARKERS='id -un >ran-as.txt
if cat "/proc/$PPID/environ" >/dev/null 2>&1; then echo yes; else echo no; fi >environ-verdict.txt
if sudo -n true 2>/dev/null; then echo yes; else echo no; fi >sudo-verdict.txt
'

make_workspace || exit 1
VERIFY_CMD="$PROBE_MARKERS$VERIFY_CMD"
run_verify_and_push 'normal /proc'
round1=$?
evidence 'normal /proc'

# ---------- 第二轮：procfs hidepid=2 ----------
# 复审点名的那台机器。普通身份看不见别人的进程，`ps -U ghwf-verify` 于是空手而归 ——
# 清点必须照旧问得出来（它走 root），分离要么成立、要么回退，绝不「静默说已经隔离」。
say 'remounting /proc with hidepid=2'
sudo -n mount -o remount,hidepid=2 /proc && echo 'remounted' || echo 'remount refused'
printf 'as the runner user, ps -U ghwf-verify now: [%s]\n' "$(ps -U ghwf-verify -o pid= 2>/dev/null | tr '\n' ';')"
printf 'as root, ps -U ghwf-verify now:            [%s]\n' "$(sudo -n ps -U ghwf-verify -o pid= 2>/dev/null | tr '\n' ';')"

make_workspace || exit 1
run_verify_and_push 'hidepid=2'
round2=$?
evidence 'hidepid=2'

# ---------- 对照 + 第三轮：hidepid=2，而且那个账号名下已经有一个活进程 ----------
# 这才是复审那条 P1 的正核：hidepid=2 下普通身份看不见那个进程，root 看得见。
# 旧代码用普通身份问 → 看不见 → 当成「名下没人」→ 照旧声称已经隔离。
# 新代码借 root 问 → 看得见 → 拒绝隔离、回退到 runner 用户并刷一条 warning。
say 'control (hidepid=2): who can see a live process owned by the account?'
sudo -n -u ghwf-verify sleep 45 </dev/null >/dev/null 2>&1 &
planted=$!
sleep 2
printf 'as the runner user: [%s]\n' "$(ps -U ghwf-verify -o pid=,args= 2>/dev/null | tr '\n' ';')"
printf 'as root:            [%s]\n' "$(sudo -n ps -U ghwf-verify -o pid=,args= 2>/dev/null | tr '\n' ';')"

make_workspace || exit 1
: >"$GITHUB_OUTPUT"; : >"$GITHUB_ENV"; : >"$GITHUB_STEP_SUMMARY"
say 'step 3/4  Verify the Claude fix  (hidepid=2, the account already owns a live process)'
FIXER=Claude VERIFY="${PROBE_MARKERS}true" VERIFY_WRITABLE_PATHS='' VERIFY_ISOLATION=auto \
  run_block 'Verify the Claude fix' 2>&1 | tee "$RUNNER_TEMP/round3.out"
round3=${PIPESTATUS[0]}
printf 'verify exit=%s\n' "$round3"
printf 'the verify command reported it ran as: %s (we are %s)\n' \
  "$(cat ran-as.txt 2>/dev/null || echo '<no marker>')" "$(id -un)"
printf 'fell back with a warning: %s\n' \
  "$(grep -c 'cannot run the verify command as a dedicated account' "$RUNNER_TEMP/round3.out" || echo 0)"
sudo -n pkill -U ghwf-verify >/dev/null 2>&1 || true
wait "$planted" >/dev/null 2>&1 || true

say 'verdict'
printf 'round 1 (normal /proc)                      exit=%s\n' "$round1"
printf 'round 2 (hidepid=2, account idle)           exit=%s\n' "$round2"
printf 'round 3 (hidepid=2, account owns a process) exit=%s\n' "$round3"
