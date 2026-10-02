#!/usr/bin/env bash
# MEL-289 第 4 轮的一次性探针（只活在探针分支上，永不进 PR）。
#
# 要定的那一件事（票面【下一步】）：验证命令以 ghwf-verify 的身份造一个**两层**目录
# （.venv/a/b/file）之后，各级目录是 0775 还是 0755，runner 回头 git clean -fdx 删不删
# 得掉深层。第 1 轮只测了一层的 .venv/marker，删得掉不能证明深层也删得掉。
#
# 三轮，同一台 runner 上跑完：
#   A  d18d0f9 的正文（umask 002 设在 sudo **外面**）—— 也就是现状
#   B  本轮改过的正文（umask 002 设在 sudo 起的那条命令**里面**）
#   C  本轮正文 + 账号机器上本来就有、又不是这一次 run 建的 → 必须退回原路径
set -uo pipefail

BASELINE=.github/mel289-baseline.yml                 # d18d0f9 的正文
FIXED=.github/workflows/claude-codex-iterate.yml     # 本轮改过的正文
SRC="$PWD"
say() { printf '\n========== %s ==========\n' "$*"; }

extract_run_block() { # extract_run_block <workflow 文件> <步骤名>
  awk -v want="      - name: $2" '
    $0 == want { in_step = 1; next }
    in_step && !in_run && $0 == "        run: |" { in_run = 1; next }
    in_run {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      if ($0 !~ /^          /)   { exit }
      sub(/^          /, "")
      print
    }
  ' "$1"
}

run_block() { # run_block <workflow 文件> <步骤名>
  local f
  f="$(mktemp "$RUNNER_TEMP/block-XXXXXX.sh")"
  extract_run_block "$SRC/$1" "$2" >"$f"
  [ -s "$f" ] || { echo "probe: no run block for '$2' in $1" >&2; return 98; }
  bash --noprofile --norc -eo pipefail "$f"
}

step_output() { # step_output <名字>
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

guards_from() { # guards_from <workflow 文件>
  : >"$GITHUB_OUTPUT"
  run_block "$1" 'Define the fix verify and push guards' || return 1
  FIX_VERIFY_GUARD="$(step_output verify)" || return 1
  FIX_PUSH_GUARD="$(step_output push)" || return 1
  export FIX_VERIFY_GUARD FIX_PUSH_GUARD
  printf 'guards from %s: verify %s lines\n' "$1" \
    "$(printf '%s\n' "$FIX_VERIFY_GUARD" | wc -l)"
}

# 工作区：本仓库自己的一份副本 + 一个本地 bare origin。位置和权限照生产的形状
# （$GITHUB_WORKSPACE 的上一级是 0750 runner:runner，专用账号靠加进 runner 组才进得去）。
make_workspace() {
  WS="$(mktemp -d "$RUNNER_TEMP/probe-ws-XXXXXX")"
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
  git config --local http.https://github.com/.extraheader 'AUTHORIZATION: basic cHJvYmU='
  printf '\n<!-- probe: the fixer touched this -->\n' >>README.md
}

# 账号每一轮都从零开始：A 轮用的是没有标记那一版的正文，它建的账号身上不会有标记，
# 留着会把 B 轮也拖进「本来就有」那条路。userdel 不带 -r（账号本来就 --no-create-home）。
fresh_account() {
  sudo -n pkill -U ghwf-verify >/dev/null 2>&1 || true
  sudo -n userdel ghwf-verify >/dev/null 2>&1 || true
  printf 'account after userdel: %s\n' "$(id -u ghwf-verify 2>/dev/null || echo '<gone>')"
}

# 验证命令：报回自己的身份和 umask，再造一个两层目录
# shellcheck disable=SC2016  # 这几行是递给验证命令的脚本文本，就该原样不展开
PROBE_VERIFY='id -un >ran-as.txt
umask >umask-seen.txt
mkdir -p .venv/a/b
: >.venv/a/b/file
stat -c "%a %U:%G %n" .venv .venv/a .venv/a/b .venv/a/b/file >perms-inside.txt 2>&1
'

report_round() { # report_round <轮次标签>
  local p status
  say "evidence ($1)"
  printf 'ran as:                  %s\n' "$(cat ran-as.txt 2>/dev/null || echo '<no marker>')"
  printf 'umask the verify saw:    %s\n' "$(cat umask-seen.txt 2>/dev/null || echo '<no marker>')"
  printf -- '--- the two-level tree, as the verify command saw it ---\n'
  cat perms-inside.txt 2>/dev/null || echo '<no marker>'
  printf -- '--- the same paths, as the runner user sees them now ---\n'
  stat -c '%a %U:%G %n' .venv .venv/a .venv/a/b .venv/a/b/file 2>&1 || true
  for p in .venv .venv/a .venv/a/b; do
    printf 'runner can write %-12s %s\n' "$p" "$([ -w "$p" ] && echo yes || echo NO)"
  done

  say "git clean as the runner user ($1)"
  git clean -fdx >"$RUNNER_TEMP/clean-$1.out" 2>&1
  status=$?
  printf 'git clean -fdx exit=%s\n' "$status"
  sed -n '1,12p' "$RUNNER_TEMP/clean-$1.out"
  for p in .venv .venv/a .venv/a/b .venv/a/b/file; do
    printf 'after clean -fdx,  %-18s still there: %s\n' "$p" \
      "$([ -e "$p" ] && echo YES || echo no)"
  done
  # 生产里用的是 -ff（见「Hand the round over to Codex」那一步）：多一个 f 管的是
  # 「没被跟踪的目录自己是个 git 仓库」，跟权限无关 —— 一并试一次，省得混淆。
  git clean -ffdx >"$RUNNER_TEMP/cleanff-$1.out" 2>&1
  status=$?
  printf 'git clean -ffdx exit=%s\n' "$status"
  sed -n '1,12p' "$RUNNER_TEMP/cleanff-$1.out"
  printf 'after clean -ffdx, .venv still there: %s\n' "$([ -e .venv ] && echo YES || echo no)"
}

# ---------- A 轮：d18d0f9 的正文（umask 在 sudo 外面）----------
say 'round A — d18d0f9 as it stands: umask 002 set OUTSIDE the sudo command'
fresh_account
guards_from "$BASELINE" || exit 1
make_workspace || exit 1
FIXER=Claude VERIFY="$PROBE_VERIFY" VERIFY_WRITABLE_PATHS='' VERIFY_ISOLATION=auto \
  run_block "$BASELINE" 'Verify the Claude fix' 2>&1 | tee "$RUNNER_TEMP/roundA.out"
a_status=${PIPESTATUS[0]}
printf 'verify exit=%s\n' "$a_status"
report_round A
cd "$SRC" || exit 1

# ---------- B 轮：本轮改过的正文（umask 在 sudo 里面）----------
say 'round B — this round: umask 002 set INSIDE the sudo command'
fresh_account
guards_from "$FIXED" || exit 1
make_workspace || exit 1
FIXER=Claude VERIFY="$PROBE_VERIFY" VERIFY_WRITABLE_PATHS='' VERIFY_ISOLATION=auto \
  run_block "$FIXED" 'Verify the Claude fix' 2>&1 | tee "$RUNNER_TEMP/roundB.out"
b_status=${PIPESTATUS[0]}
printf 'verify exit=%s\n' "$b_status"
MARK="/run/ghwf-verify.$GITHUB_RUN_ID.$GITHUB_RUN_ATTEMPT"
printf 'marker this run left behind: [%s]\n' "$(sudo -n ls -ldn "$MARK" 2>/dev/null)"
printf 'marker content (should be the account uid): [%s]\n' "$(sudo -n cat "$MARK" 2>/dev/null)"
report_round B
cd "$SRC" || exit 1

# ---------- C 轮：账号机器上本来就有、不是这一次 run 建的 ----------
# 持久的自建 runner 上第二次 run 就是这个形状（账号留着、标记换了文件名）。
# 这里用「重跑次数换一个数」把它摆出来：标记在 /run 下的名字带 run 号 + 重跑次数。
say 'round C — the account was already on the machine and THIS run did not create it'
fresh_account
sudo -n useradd --system --no-create-home --shell /usr/sbin/nologin ghwf-verify
printf 'planted a pre-existing account: uid=%s groups=%s\n' \
  "$(id -u ghwf-verify)" "$(id -nG ghwf-verify)"
make_workspace || exit 1
: >"$GITHUB_OUTPUT"; : >"$GITHUB_ENV"; : >"$GITHUB_STEP_SUMMARY"
FIXER=Claude VERIFY="$PROBE_VERIFY" VERIFY_WRITABLE_PATHS='' VERIFY_ISOLATION=auto \
  GITHUB_RUN_ATTEMPT=99 \
  run_block "$FIXED" 'Verify the Claude fix' 2>&1 | tee "$RUNNER_TEMP/roundC.out"
c_status=${PIPESTATUS[0]}
printf 'verify exit=%s\n' "$c_status"
printf 'ran as: %s   (we are %s)\n' "$(cat ran-as.txt 2>/dev/null || echo '<no marker>')" "$(id -un)"
printf 'fell back with the warning: %s hit(s)\n' \
  "$(grep -c 'cannot run the verify command as a dedicated account' "$RUNNER_TEMP/roundC.out" || true)"
cd "$SRC" || exit 1

say 'verdict'
printf 'round A (umask outside sudo)        verify exit=%s\n' "$a_status"
printf 'round B (umask inside sudo)         verify exit=%s\n' "$b_status"
printf 'round C (account not ours this run) verify exit=%s\n' "$c_status"
