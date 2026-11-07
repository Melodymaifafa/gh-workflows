#!/usr/bin/env bats
# Mac 上的巡检自己跟上 develop，常驻脚本自己变了就退出让 pm2 拉起（MEL-600）。
# 假仓库：一个裸「远端」，一个推提交用的 seed，一个克隆（巡检就跑在克隆里）。替身 sleep 退出非 0，跑完一轮循环就停。

load test_helper/common

setup() {
  stubs="$BATS_TEST_TMPDIR/stubs" out="$BATS_TEST_TMPDIR/out" err="$BATS_TEST_TMPDIR/err" code="$BATS_TEST_TMPDIR/code"
  remote="$BATS_TEST_TMPDIR/remote.git" seed="$BATS_TEST_TMPDIR/seed" clone="$BATS_TEST_TMPDIR/clone"
  mkdir -p "$stubs"
  unset PUSHOVER_TOKEN PUSHOVER_USER
  # 不读本机的 git 配置：提交签名、全局钩子都不该影响判定。
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  # 临时目录碰巧在别的仓库里时，「不是 git 仓库」那条也不往外找。
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e
  export GH_WORKFLOWS_SECRETS="$BATS_TEST_TMPDIR/secrets.env"
  echo 'CODEX_TRIGGER_TOKEN=top-secret' >"$GH_WORKFLOWS_SECRETS"
  stub gh 'echo live'
  stub sleep 'exit 1'

  git init -q --bare -b develop "$remote"
  git init -q -b develop "$seed"
  git -C "$seed" remote add origin "$remote"
  mkdir -p "$seed/scripts"
  cp "$REPO_ROOT/scripts/pr-sweep-local.sh" "$seed/scripts/"
  printf '%s\n' '#!/usr/bin/env bash' 'echo sweep-ran' >"$seed/scripts/pr-sweep.sh"
  chmod +x "$seed/scripts/pr-sweep.sh"
  echo one >"$seed/notes.txt"
  git -C "$seed" add -A
  git -C "$seed" commit -q -m first
  git -C "$seed" push -q origin develop
  git clone -q -b develop "$remote" "$clone"
  start="$(git -C "$clone" rev-parse HEAD)"
}

# stub <命令> <脚本正文>：PATH 最前面放一个替身命令。
stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$stubs/$1"
  chmod +x "$stubs/$1"
}

# stub_sleep_runs <命令>：第一次 sleep 跑这条命令再放行；第二次让循环停，脚本没退出时测试不至于卡死。
stub_sleep_runs() {
  slept="$BATS_TEST_TMPDIR/slept"
  stub sleep "[ ! -e '$slept' ] || exit 1
touch '$slept'
$1"
}

# run_split <命令…>：stdout 存进 $out、stderr 存进 $err、退出码存进 $code。
run_split() {
  { {
    local rc=0
    PATH="$stubs:$PATH" "$@" || rc=$?
    echo "$rc" >"$code"
  } 2>&1 >&3 3>&- | cat >"$err"; } 3>&1 | cat >"$out"
}

run_sweep() { run_split bash "$clone/scripts/pr-sweep-local.sh"; }

# seed_commit <文件> [内容]：seed 多一个提交（还没推），改的是这个文件。提交号存进 $new。
seed_commit() {
  printf '%s\n' "${2:-# changed}" >>"$seed/$1"
  git -C "$seed" add -A
  git -C "$seed" commit -q -m "change $1"
  new="$(git -C "$seed" rev-parse HEAD)"
}

# remote_commit <文件> [内容]：同上，再推到远端 develop。
remote_commit() {
  seed_commit "$@"
  git -C "$seed" push -q origin develop
}

# setup_pool：runner 池的一份副本（它开头要读 runner/Dockerfile），docker 连不上，循环只走到 sleep。
setup_pool() {
  local pool="$BATS_TEST_TMPDIR/pool"
  pool_script="$pool/scripts/runner-pool.sh"
  mkdir -p "$pool/scripts" "$pool/runner"
  cp "$REPO_ROOT/scripts/runner-pool.sh" "$pool/scripts/"
  cp "$REPO_ROOT/runner/Dockerfile" "$pool/runner/"
  stub docker 'exit 1'
  stub colima 'exit 0'
}

run_pool() {
  RUNNER_POOL_STATE="$BATS_TEST_TMPDIR/state" GH_WORKFLOWS_SECRETS="$BATS_TEST_TMPDIR/none" \
    run_split bash "$pool_script"
}

assert_head() { assert_equal "$(git -C "$clone" rev-parse HEAD)" "$1"; }
assert_swept() { assert_equal "$(grep -c '^sweep-ran$' "$out")" "${1:-1}"; }
assert_code() { assert_equal "$(cat "$code")" "$1"; }

@test "clean develop: pulls to the newest commit, logs its short SHA, then sweeps" {
  remote_commit notes.txt two
  run_sweep
  assert_head "$new"
  grep -qx "自更新：更新到了 $(git -C "$seed" rev-parse --short HEAD)" "$out"
  assert_swept
  # 替身 sleep 退出非 0：这一轮跑到了 sleep，不是提前退出。
  assert_code 1
}

@test "a pull that brings a new pr-sweep.sh sweeps with it in the same round" {
  remote_commit scripts/pr-sweep.sh 'echo sweep-new'
  run_sweep
  assert_head "$new"
  grep -qx sweep-new "$out"
  assert_code 1
}

@test "already up to date: no update line, and the sweep runs" {
  run_sweep
  assert_head "$start"
  refute_contains "$(cat "$out")" "更新到了"
  assert_swept
}

@test "dirty tracked file: does not pull, keeps the edit, logs the skip, still sweeps" {
  remote_commit notes.txt two
  echo edit >>"$clone/notes.txt"
  run_sweep
  assert_head "$start"
  assert_equal "$(cat "$clone/notes.txt")" "one
edit"
  grep -qx "自更新：本机仓库有没提交的改动，跳过" "$out"
  assert_swept
}

@test "a staged change counts as dirty too" {
  remote_commit notes.txt two
  echo edit >>"$clone/notes.txt"
  git -C "$clone" add notes.txt
  run_sweep
  assert_head "$start"
  grep -qx "自更新：本机仓库有没提交的改动，跳过" "$out"
  assert_swept
}

@test "an untracked file is not dirty: still pulls" {
  remote_commit notes.txt two
  echo temp >"$clone/left-by-pm2.tmp"
  run_sweep
  assert_head "$new"
  [ -e "$clone/left-by-pm2.tmp" ]
  assert_swept
}

@test "on another branch: does not pull, logs the skip, still sweeps" {
  remote_commit notes.txt two
  git -C "$clone" checkout -q -b topic
  run_sweep
  assert_head "$start"
  assert_equal "$(git -C "$clone" rev-parse develop)" "$start"
  assert_equal "$(git -C "$clone" symbolic-ref --short HEAD)" topic
  grep -qx "自更新：本机仓库在 topic，不在 develop，跳过" "$out"
  assert_swept
}

@test "detached HEAD counts as not on develop" {
  remote_commit notes.txt two
  git -C "$clone" checkout -q --detach
  run_sweep
  assert_head "$start"
  assert_contains "$(cat "$out")" "不在 develop，跳过"
  assert_swept
}

@test "pull failure: logs git's reason on one line, and the round still sweeps" {
  git -C "$clone" remote set-url origin "$BATS_TEST_TMPDIR/no-such-remote"
  run_sweep
  assert_head "$start"
  assert_equal "$(grep -c '^自更新：git pull 失败，这一轮照跑：.*no-such-remote' "$out")" 1
  # 失败原因压成一行：除了 == 时间 ==、这一行和巡检，没有别的。
  assert_equal "$(wc -l <"$out" | tr -d ' ')" 3
  assert_swept
  assert_code 1
}

@test "a diverged develop is a failed pull: --ff-only leaves the local commit alone" {
  remote_commit notes.txt two
  echo mine >"$clone/mine.txt"
  git -C "$clone" add mine.txt
  git -C "$clone" commit -q -m mine
  local mine
  mine="$(git -C "$clone" rev-parse HEAD)"
  run_sweep
  assert_head "$mine"
  assert_contains "$(cat "$out")" "自更新：git pull 失败"
  assert_swept
}

@test "the pull runs outside the secrets, and cannot wait forever on a password or a dead connection" {
  local real_git env_dump="$BATS_TEST_TMPDIR/git-env"
  real_git="$(command -v git)"
  stub git "env >>'$env_dump'
exec '$real_git' \"\$@\""
  remote_commit notes.txt two
  run_sweep
  assert_head "$new"
  assert_contains "$(cat "$env_dump")" "GIT_TERMINAL_PROMPT=0"
  assert_contains "$(cat "$env_dump")" "GIT_HTTP_LOW_SPEED_LIMIT=1"
  assert_contains "$(cat "$env_dump")" "GIT_HTTP_LOW_SPEED_TIME=60"
  refute_contains "$(cat "$env_dump")" "top-secret"
}

@test "not a git repository: logs one skip line, and the round still sweeps" {
  local mac="$BATS_TEST_TMPDIR/mac"
  mkdir -p "$mac"
  cp "$clone/scripts/pr-sweep-local.sh" "$clone/scripts/pr-sweep.sh" "$mac/"
  run_split bash "$mac/pr-sweep-local.sh"
  assert_equal "$(grep -c '^自更新：.*不是 git 仓库，跳过$' "$out")" 1
  assert_swept
  assert_code 1
  [ ! -s "$err" ]
}

@test "the pull changes the sweep script itself: logs both lines, exits 0, and does not sweep" {
  remote_commit scripts/pr-sweep-local.sh
  run_sweep
  assert_head "$new"
  assert_code 0
  grep -qx "自更新：更新到了 $(git -C "$seed" rev-parse --short HEAD)" "$out"
  grep -qx "自更新：pr-sweep-local.sh 变了，退出让 pm2 拉起新代码" "$out"
  assert_swept 0
  [ ! -s "$err" ]
}

@test "someone else updates the sweep script between rounds: exits 0 on the next round" {
  # 歇着的时候有人手动拉了：下一轮 HEAD 已经是新的，自己什么也没拉到，靠比文件内容发现。
  seed_commit scripts/pr-sweep-local.sh
  stub_sleep_runs "git -C '$seed' push -q origin develop
git -C '$clone' pull -q --ff-only origin develop"
  run_sweep
  assert_head "$new"
  assert_code 0
  [ -e "$slept" ]
  grep -qx "自更新：pr-sweep-local.sh 变了，退出让 pm2 拉起新代码" "$out"
  refute_contains "$(cat "$out")" "更新到了"
  assert_swept 1
}

@test "runner pool: its own file changes, so it logs a stamped line and exits 0" {
  setup_pool
  stub_sleep_runs "echo '# changed' >>'$pool_script'"
  run_pool
  assert_code 0
  # 第一圈文件没变，照常干活；变了之后下一圈退出。
  [ -e "$slept" ]
  assert_contains "$(cat "$out")" "连不上 colima 里的 docker"
  grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} 自更新：runner-pool\.sh 变了，退出让 pm2 拉起新代码$' "$out"
}

@test "runner pool: an unchanged file keeps the loop going" {
  setup_pool
  stub_sleep_runs ':'
  run_pool
  # 第二次 sleep 才让循环停：退出码 1，一路没有「变了」。
  assert_code 1
  refute_contains "$(cat "$out")" "变了"
}
