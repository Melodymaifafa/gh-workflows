#!/usr/bin/env bats
# 主人 Mac 上 pm2 的日志每行带时间：runner 池两路都带；本机巡检只有 stderr 带，stdout 照旧（每轮有 == 时间 ==）。

load test_helper/common

STAMP='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} '

setup() {
  stubs="$BATS_TEST_TMPDIR/stubs" out="$BATS_TEST_TMPDIR/out" err="$BATS_TEST_TMPDIR/err"
  mkdir -p "$stubs"
  unset PUSHOVER_TOKEN PUSHOVER_USER
}

# stub <命令> <脚本正文>：PATH 最前面放一个替身命令。
stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$stubs/$1"
  chmod +x "$stubs/$1"
}

# run_split <命令…>：stdout 存进 $out、stderr 存进 $err。两头的 cat 等所有写的进程都关了才返回，
# 所以加时间的子进程写完了才读。
run_split() {
  { PATH="$stubs:$PATH" "$@" 2>&1 >&3 3>&- | cat >"$err"; } 3>&1 | cat >"$out"
}

# assert_stamped <文件>：有内容，而且每一行都以「日期 时间 」开头。
assert_stamped() {
  [ -s "$1" ] || { echo "empty: $1" >&2; return 1; }
  if grep -Ev "$STAMP" "$1" >&2; then echo "^ lines without a timestamp in $1" >&2; return 1; fi
}

@test "runner pool run by pm2: every stdout and stderr line starts with the date and time" {
  # docker 连不上：脚本自己往 stdout、stderr 各写一行；替身 sleep 也各写一行，然后让循环停下。
  stub docker 'exit 1'
  stub colima 'exit 0'
  stub sleep 'echo sleep-out; echo sleep-err >&2; exit 1'
  RUNNER_POOL_STATE="$BATS_TEST_TMPDIR/state" GH_WORKFLOWS_SECRETS="$BATS_TEST_TMPDIR/none" \
    run_split bash "$REPO_ROOT/scripts/runner-pool.sh"
  assert_stamped "$out"
  assert_stamped "$err"
  assert_contains "$(cat "$out")" "连不上 colima 里的 docker"
  assert_contains "$(cat "$out")" " sleep-out"
  assert_contains "$(cat "$err")" "colima 里的 docker 起不来"
  assert_contains "$(cat "$err")" " sleep-err"
}

@test "runner pool sourced by the tests: nothing is redirected" {
  run bash -c '. "$1"; echo plain; echo plain-err >&2' _ "$REPO_ROOT/scripts/runner-pool.sh"
  assert_equal "$output" "plain
plain-err"
}

@test "Mac sweep loop: every stderr line is stamped, stdout keeps its format" {
  local mac="$BATS_TEST_TMPDIR/mac"
  mkdir -p "$mac"
  cp "$REPO_ROOT/scripts/pr-sweep-local.sh" "$mac/"
  # 替身 pr-sweep.sh 各写一行再失败：循环自己再往 stderr 写一句「这一轮失败」。
  printf '%s\n' '#!/usr/bin/env bash' 'echo sweep-out' 'echo sweep-err >&2' 'exit 1' >"$mac/pr-sweep.sh"
  chmod +x "$mac/pr-sweep.sh"
  stub gh 'echo live'
  stub sleep 'exit 1'
  echo 'CODEX_TRIGGER_TOKEN=x' >"$BATS_TEST_TMPDIR/secrets.env"
  GH_WORKFLOWS_SECRETS="$BATS_TEST_TMPDIR/secrets.env" run_split bash "$mac/pr-sweep-local.sh"
  assert_stamped "$err"
  assert_contains "$(cat "$err")" " sweep-err"
  assert_contains "$(cat "$err")" "这一轮失败（退出码 1）"
  # stdout 不加时间：第一行是 == 时间 ==，替身的那行原样。
  grep -Eq '^== [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} ==$' "$out"
  grep -qx sweep-out "$out"
  run grep -E "$STAMP" "$out"
  assert_equal "$status" 1
}

@test "the timestamp filter keeps a last line that has no newline" {
  local script
  for script in runner-pool.sh pr-sweep-local.sh; do
    eval "$(sed -n '/^stamp() {$/,/^}$/p' "$REPO_ROOT/scripts/$script")"
    printf 'first\nlast' | stamp >"$out"
    assert_stamped "$out"
    assert_equal "$(wc -l <"$out" | tr -d ' ')" 2
    assert_equal "$(sed -E "s/$STAMP//" "$out")" "first
last"
    unset -f stamp
  done
}
