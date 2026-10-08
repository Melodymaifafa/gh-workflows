#!/usr/bin/env bats
# PR 跟集成分支冲突时，合并环节把集成分支合进 PR 分支（codex-approved-merge.yml 的 resolve-conflict）。
# 跑的是 workflow 里的真 run 块：git 是真的（本地 bare 仓库当 origin），gh / curl / sleep / date 是假的，
# Claude 那一步由测试直接改文件代替。

# bats 每个 @test 是子 shell；字面量 ${{ }} 是要比对的文本。
# shellcheck disable=SC2016,SC2030,SC2031,SC2153,SC2155

load test_helper/common

WF=.github/workflows/codex-approved-merge.yml
GATE='Decide whether to merge the base branch in'
MERGE='Merge the base branch into the PR branch'
CHECK='Check the resolution and commit it'
PUSH='Push the merge or hand it to a person'
H=1a7e81f6b5f27f0a1dbc33c6fafda1bb86f1483d
OTHER=9b14fe3c0de5a1b2c3d4e5f60718293a4b5c6d7e
RESOLVED='{"verdict":"resolved","files":[{"path":"app.txt","how":"两边各改了第二行，合成了一行"}],"summary_zh":"解完了"}'

setup() {
  setup_fake_env
  REAL_GIT="$(command -v git)"
  export REPO=o/r PR_NUMBER=7 BASE_BRANCH=develop GITHUB_RUN_ID=111
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp" PUSHOVER_TOKEN=pt PUSHOVER_USER=pu
  mkdir -p "$RUNNER_TEMP"
  fake_route "repos/o/r/issues/7/comments?per_page=100" '[]'
}

# pr_json [head] [mergeable_state] [title]
pr_json() {
  jq -n --arg h "${1:-$H}" --arg ms "${2:-dirty}" --arg t "${3:-feat: x}" '{
    state: "open", draft: false, title: $t, body: "why <!-- hidden --> this",
    mergeable: false, mergeable_state: $ms,
    base: {ref: "develop"}, head: {sha: $h, ref: "topic", repo: {full_name: "o/r"}}
  }'
}

refute_output_key() {
  if step_output "$1" >/dev/null; then
    echo "unexpected output $1=$(step_output "$1")" >&2
    return 1
  fi
}

# step_text <step>：这一步的整段 YAML（到下一步为止）。
step_text() {
  awk -v want="      - name: $1" '$0 == want { f = 1; print; next } f && /^      - / { exit } f' "$REPO_ROOT/$WF"
}

job_text() { awk '/^  resolve-conflict:/ { f = 1 } f' "$REPO_ROOT/$WF"; }

# ---------- 叫醒之后先判断：解不解、解哪个 head ----------

gate_env() {
  export GH_TOKEN=actions-token WATCH_CONFLICT='' WATCH_HEAD='' FAKE_NOW=2026-10-08T08:00:00Z
  export COMMENT_BODY="🤖 巡检：有冲突。"$'\n\n'"$(m6_marker "$H" conflict)"
  fake_route repos/o/r/pulls/7 "$(pr_json)"
}

@test "gate: the sweeper's conflict marker starts a resolution of that exact head" {
  gate_env
  run run_step "$WF" "$GATE"
  assert_equal "$status" 0
  assert_equal "$(step_output run)" true
  assert_equal "$(step_output head)" "$H"
  assert_equal "$(step_output ref)" topic
  assert_equal "$(step_output no_claude)" false
}

@test "gate: a [no-claude] title still proceeds, flagged so Claude never touches it" {
  gate_env
  export WATCH_CONFLICT=true WATCH_HEAD="$H" COMMENT_BODY=''
  fake_route repos/o/r/pulls/7 "$(pr_json "$H" dirty '[no-claude] feat: x')"
  run run_step "$WF" "$GATE"
  assert_equal "$status" 0
  assert_equal "$(step_output run)" true
  assert_equal "$(step_output no_claude)" true
}

@test "gate: the merge watcher hands a conflicted head over directly" {
  gate_env
  export WATCH_CONFLICT=true WATCH_HEAD="$H" COMMENT_BODY=''
  run run_step "$WF" "$GATE"
  assert_equal "$status" 0
  assert_equal "$(step_output run)" true
  assert_equal "$(step_output head)" "$H"
}

@test "gate: a moved head, a conflict that is gone, or an opted-out title does nothing" {
  gate_env
  for pr in "$(pr_json "$OTHER")" "$(pr_json "$H" clean)" "$(pr_json "$H" blocked)" \
    "$(pr_json "$H" dirty '[no-codex-merge] x')"; do
    : >"$GITHUB_OUTPUT"
    fake_route repos/o/r/pulls/7 "$pr"
    run run_step "$WF" "$GATE"
    assert_equal "$status" 0
    refute_output_key run
  done
}

@test "gate: a comment that names no single conflicted head does nothing" {
  gate_env
  for body in '@codex review' "$(m6_marker "$H" conflict-stuck)" \
    "$(m6_marker "$H" conflict)"$'\n'"$(m6_marker "$OTHER" conflict)"; do
    : >"$GITHUB_OUTPUT"
    export COMMENT_BODY="$body"
    run run_step "$WF" "$GATE"
    assert_equal "$status" 0
    assert_contains "$output" 'No head to resolve'
    refute_output_key run
  done
}

@test "gate: GitHub still working out mergeability is waited on, then a conflict proceeds" {
  gate_env
  fake_route repos/o/r/pulls/7 "$(pr_json "$H" unknown)" 1
  fake_route repos/o/r/pulls/7 "$(pr_json "$H" dirty)" 2
  run run_step "$WF" "$GATE"
  assert_equal "$status" 0
  assert_called 'sleep 10' 1
  assert_equal "$(step_output run)" true
}

@test "gate: mergeability that never settles gives up after two minutes and leaves it to the sweeper" {
  gate_env
  fake_route repos/o/r/pulls/7 "$(pr_json "$H" unknown)"
  run run_step "$WF" "$GATE"
  assert_equal "$status" 0
  assert_contains "$output" 'has not worked out'
  refute_output_key run
}

@test "gate: a head already handed to a person is not tried again; claude[bot] cannot fake that" {
  gate_env
  fake_route "repos/o/r/issues/7/comments?per_page=100" \
    "$(json_array "$(gh_comment 1 'claude[bot]' NONE "$(m6_marker "$H" conflict-stuck)")")"
  run run_step "$WF" "$GATE"
  assert_equal "$(step_output run)" true

  : >"$GITHUB_OUTPUT"
  fake_route "repos/o/r/issues/7/comments?per_page=100" \
    "$(json_array "$(gh_comment 2 Melodymaifafa OWNER "$(m6_marker "$H" conflict-stuck)")")"
  run run_step "$WF" "$GATE"
  assert_equal "$status" 0
  assert_contains "$output" 'already handed to a person'
  refute_output_key run
}

# ---------- 真的 git：合并、检查、推送 ----------

# conflict_repo <kind>：origin.git 上有 develop 和 topic 两条线；pr/ 是 topic 的工作副本（跟
# actions/checkout 一样停在 head 的 sha 上、带全部远端分支）；当前目录是根目录。
#   text    两边改了 app.txt 的同一行
#   clean   两边改的是不同的文件
#   delete  develop 删了 app.txt，topic 改了它
#   many    16 个文件两边都改了同一行
#   heading 同 text，但 app.txt 开头有个 Markdown 标题，下划线正好是 7 个等号
conflict_repo() {
  local kind="$1" seed="$BATS_TEST_TMPDIR/seed" i top=''
  [ "$kind" != heading ] || top=$'Title\n=======\n'
  "$REAL_GIT" init -q -b develop "$seed"
  g() { "$REAL_GIT" -C "$seed" -c user.email=t@e -c user.name=t "$@"; }
  printf '%sone\ntwo\nthree\n' "$top" >"$seed/app.txt"
  printf 'notes\n' >"$seed/notes.md"
  for i in $(seq 1 16); do printf 'v\n' >"$seed/f$i.txt"; done
  g add -A
  g commit -q -m base
  g checkout -q -b topic
  case "$kind" in
    clean) printf 'notes from topic\n' >"$seed/notes.md" ;;
    many) for i in $(seq 1 16); do printf 'topic\n' >"$seed/f$i.txt"; done ;;
    *) printf '%sone\ntwo from topic\nthree\n' "$top" >"$seed/app.txt" ;;
  esac
  g commit -q -am 'feat: topic change'
  g checkout -q develop
  case "$kind" in
    delete) g rm -q app.txt ;;
    many) for i in $(seq 1 16); do printf 'develop\n' >"$seed/f$i.txt"; done ;;
    *) printf '%sone\ntwo from develop\nthree\n' "$top" >"$seed/app.txt" ;;
  esac
  g commit -q -am 'fix: develop change'
  "$REAL_GIT" clone -q --bare "$seed" "$BATS_TEST_TMPDIR/origin.git"
  mkdir -p "$BATS_TEST_TMPDIR/ws"
  cd "$BATS_TEST_TMPDIR/ws" || return 1
  "$REAL_GIT" clone -q "$BATS_TEST_TMPDIR/origin.git" pr
  HEAD_SHA="$("$REAL_GIT" -C pr rev-parse origin/topic)"
  "$REAL_GIT" -C pr checkout -q --detach "$HEAD_SHA"
  export HEAD_SHA HEAD_REF=topic GH_TOKEN=actions-token
  fake_route repos/o/r/pulls/7 "$(pr_json "$HEAD_SHA")"
}

origin_topic() { "$REAL_GIT" -C "$BATS_TEST_TMPDIR/origin.git" rev-parse topic; }
pr_git() { "$REAL_GIT" -C pr "$@"; }

# 跑合并那一步，把指纹交给检查那一步（真跑时走 step 输出）。
merge_step() {
  run_step "$WF" "$MERGE" >/dev/null
  FINGERPRINT="$(step_output fingerprint)"
  export FINGERPRINT
  : >"$GITHUB_OUTPUT"
}

# 代替 Claude：把冲突段落改成两边都保住的那一行。
claude_resolves() {
  printf 'one\ntwo from topic and develop\nthree\n' >pr/app.txt
  export OUTCOME=success STRUCTURED_OUTPUT="${1:-$RESOLVED}"
}

@test "merge: a text conflict is left for Claude with both sides' story; nothing is pushed" {
  conflict_repo text
  run run_step "$WF" "$MERGE"
  assert_equal "$status" 0
  assert_equal "$(step_output conflicted)" 1
  [ -n "$(step_output fingerprint)" ]
  refute_output_key stuck
  grep -q '^<<<<<<< ' pr/app.txt
  assert_equal "$(cat .conflict/files.txt)" $'1\tapp.txt'
  assert_contains "$(cat .conflict/diffs/1.base.diff)" '+two from develop'
  assert_contains "$(cat .conflict/diffs/1.pr.diff)" '+two from topic'
  assert_equal "$(cat .conflict/base-log.md)" '- fix: develop change'
  assert_equal "$(cat .conflict/pr-log.md)" '- feat: topic change'
  # PR 正文里的 HTML 注释给 Claude 之前就去掉。
  assert_equal "$(cat .conflict/pr.md)" "# feat: x"$'\n\n'"why  this"
  # 后面几步认的清单和 git 留下的原样不在 Claude 改得到的地方。
  [ -s "$RUNNER_TEMP/conflicted.z" ]
  cmp -s "$RUNNER_TEMP/conflicted/1" pr/app.txt
  assert_equal "$(origin_topic)" "$HEAD_SHA"
}

@test "merge: a clean merge needs no Claude and becomes a normal merge commit" {
  conflict_repo clean
  run run_step "$WF" "$MERGE"
  assert_equal "$status" 0
  assert_equal "$(step_output ready)" true
  refute_output_key conflicted
  assert_equal "$(pr_git rev-list --parents -n 1 HEAD)" \
    "$(pr_git rev-parse HEAD) $HEAD_SHA $(pr_git rev-parse origin/develop)"
  assert_equal "$(pr_git log -1 --format=%s)" 'Merge develop into topic'
  assert_equal "$(pr_git log -1 --format=%an)" 'github-actions[bot]'
}

@test "merge: the PR's own git hooks and the machine's git config never run" {
  conflict_repo clean
  printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$BATS_TEST_TMPDIR" >pr/.git/hooks/prepare-commit-msg
  chmod +x pr/.git/hooks/prepare-commit-msg
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  printf '[core]\n\thooksPath = %s/pr/.git/hooks\n' "$PWD" >"$HOME/.gitconfig"
  run run_step "$WF" "$MERGE"
  assert_equal "$status" 0
  assert_equal "$(step_output ready)" true
  [ ! -e "$BATS_TEST_TMPDIR/hook-ran" ]
}

@test "merge: a [no-claude] PR still gets a clean merge; no Claude is needed for that" {
  conflict_repo clean
  export NO_CLAUDE=true
  run run_step "$WF" "$MERGE"
  assert_equal "$status" 0
  assert_equal "$(step_output ready)" true
  refute_output_key stuck
}

@test "merge: a [no-claude] text conflict is never laid out for Claude" {
  conflict_repo text
  export NO_CLAUDE=true
  run run_step "$WF" "$MERGE"
  assert_equal "$status" 0
  assert_equal "$(step_output stuck)" no-claude
  refute_output_key conflicted
  [ ! -e .conflict ]
  assert_equal "$(origin_topic)" "$HEAD_SHA"
}

@test "merge: a file deleted on one side goes to a person, not to Claude" {
  conflict_repo delete
  run run_step "$WF" "$MERGE"
  assert_equal "$status" 0
  assert_equal "$(step_output stuck)" unsupported
  assert_contains "$(step_output detail)" app.txt
  refute_output_key conflicted
}

@test "merge: more than 15 conflicted files go to a person" {
  conflict_repo many
  run run_step "$WF" "$MERGE"
  assert_equal "$status" 0
  assert_equal "$(step_output stuck)" too-many
  assert_equal "$(step_output detail)" 16
}

@test "check: a clean resolution becomes one merge commit with both parents" {
  conflict_repo text
  merge_step
  claude_resolves
  run run_step "$WF" "$CHECK"
  assert_equal "$status" 0
  assert_equal "$(step_output ready)" true
  assert_equal "$(pr_git rev-list --parents -n 1 HEAD)" \
    "$(pr_git rev-parse HEAD) $HEAD_SHA $(pr_git rev-parse origin/develop)"
  assert_equal "$(pr_git show HEAD:app.txt)" $'one\ntwo from topic and develop\nthree'
  # git 记在合并说明里的「# Conflicts:」那几行不进提交。
  assert_equal "$(pr_git log -1 --format=%B | sed '/^$/d')" 'Merge develop into topic'
  assert_equal "$(origin_topic)" "$HEAD_SHA"
}

@test "check: leftover conflict markers throw the result away" {
  conflict_repo text
  merge_step
  export OUTCOME=success STRUCTURED_OUTPUT="$RESOLVED"
  run run_step "$WF" "$CHECK"
  assert_equal "$status" 0
  assert_equal "$(step_output stuck)" markers-left
  assert_contains "$(step_output detail)" app.txt
  assert_equal "$(pr_git rev-parse HEAD)" "$HEAD_SHA"
}

@test "check: a leftover ======= separator throws the result away; a heading underline already there does not" {
  conflict_repo text
  merge_step
  claude_resolves
  printf 'one\ntwo from topic\n=======\ntwo from develop\nthree\n' >pr/app.txt
  run run_step "$WF" "$CHECK"
  assert_equal "$status" 0
  assert_equal "$(step_output stuck)" markers-left
  assert_equal "$(pr_git rev-parse HEAD)" "$HEAD_SHA"

  rm -rf "$BATS_TEST_TMPDIR/seed" "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/ws"
  : >"$GITHUB_OUTPUT"
  conflict_repo heading
  merge_step
  claude_resolves
  printf 'Title\n=======\none\ntwo from topic\n=======\ntwo from develop\nthree\n' >pr/app.txt
  run run_step "$WF" "$CHECK"
  assert_equal "$(step_output stuck)" markers-left
  assert_equal "$(pr_git rev-parse HEAD)" "$HEAD_SHA"

  : >"$GITHUB_OUTPUT"
  printf 'Title\n=======\none\ntwo from topic and develop\nthree\n' >pr/app.txt
  run run_step "$WF" "$CHECK"
  assert_equal "$status" 0
  assert_equal "$(step_output ready)" true
  assert_equal "$(pr_git show HEAD:app.txt)" $'Title\n=======\none\ntwo from topic and develop\nthree'
}

# 冲突段落以外的行：改了、删了、跟新内容粘成一行，都算动过。
@test "check: a touched line outside the conflict hunks throws the result away" {
  local now
  for now in 'one, edited\ntwo from topic and develop\nthree\n' 'one\ntwo from topic and develop\n' \
    'one\ntwo from topic and developthree\n' 'one\ntwo from topic and develop\nthree\nfour\n'; do
    rm -rf "$BATS_TEST_TMPDIR/seed" "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/ws"
    : >"$GITHUB_OUTPUT"
    conflict_repo text
    merge_step
    claude_resolves
    printf '%b' "$now" >pr/app.txt
    run run_step "$WF" "$CHECK"
    assert_equal "$status" 0
    assert_equal "$(step_output stuck)" touched-outside
    assert_contains "$(step_output detail)" app.txt
    assert_equal "$(pr_git rev-parse HEAD)" "$HEAD_SHA"
  done
}

@test "check: a hunk may become several lines, or none, as long as everything around it stays" {
  local now
  for now in 'one\ntwo from topic\ntwo from develop\nthree\n' 'one\nthree\n'; do
    rm -rf "$BATS_TEST_TMPDIR/seed" "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/ws"
    : >"$GITHUB_OUTPUT"
    conflict_repo text
    merge_step
    claude_resolves
    printf '%b' "$now" >pr/app.txt
    run run_step "$WF" "$CHECK"
    assert_equal "$status" 0
    assert_equal "$(step_output ready)" true
  done
}

@test "check: any change outside the conflicted files throws the result away" {
  for extra in 'printf "edited\n" >pr/notes.md' 'printf "new\n" >pr/new.txt'; do
    rm -rf "$BATS_TEST_TMPDIR/seed" "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/ws"
    : >"$GITHUB_OUTPUT"
    conflict_repo text
    merge_step
    claude_resolves
    eval "$extra"
    run run_step "$WF" "$CHECK"
    assert_equal "$status" 0
    assert_equal "$(step_output stuck)" touched-other
    assert_equal "$(pr_git rev-parse HEAD)" "$HEAD_SHA"
  done
}

@test "check: a changed .git config or hook throws the result away before git runs again" {
  conflict_repo text
  merge_step
  claude_resolves
  pr_git config core.fsmonitor "touch $BATS_TEST_TMPDIR/fsmonitor-ran"
  run run_step "$WF" "$CHECK"
  assert_equal "$(step_output stuck)" git-tampered
  [ ! -e "$BATS_TEST_TMPDIR/fsmonitor-ran" ]

  pr_git config --unset core.fsmonitor
  : >"$GITHUB_OUTPUT"
  printf '#!/bin/sh\n' >pr/.git/hooks/post-commit
  run run_step "$WF" "$CHECK"
  assert_equal "$(step_output stuck)" git-tampered
  assert_equal "$(pr_git rev-parse HEAD)" "$HEAD_SHA"
}

@test "check: Claude giving up, failing, or answering out of shape commits nothing" {
  conflict_repo text
  merge_step
  claude_resolves '{"verdict":"give_up","files":[],"summary_zh":"超时两边改成了不同的值"}'
  run run_step "$WF" "$CHECK"
  assert_equal "$(step_output stuck)" claude-gave-up

  for case in 'failure|'"$RESOLVED" 'success|' 'success|{"verdict":"ok"}'; do
    : >"$GITHUB_OUTPUT"
    export OUTCOME="${case%%|*}" STRUCTURED_OUTPUT="${case#*|}"
    run run_step "$WF" "$CHECK"
    assert_equal "$(step_output stuck)" claude-failed
  done
  assert_equal "$(pr_git rev-parse HEAD)" "$HEAD_SHA"
}

push_env() {
  export READY=true STUCK='' DETAIL='' CONFLICTED=1 GH_TOKEN=pat-token SELF_WORKFLOWS_TOKEN=''
}

resolved_and_committed() {
  conflict_repo text
  merge_step
  claude_resolves
  run_step "$WF" "$CHECK" >/dev/null
  NEW="$(pr_git rev-parse HEAD)"
  push_env
}

# nth_body <n> <fixed-string>：第 n 条匹配调用的正文。
nth_body() {
  local line
  line="$(grep -nF -- "$2" "$FAKE_LOG" | sed -n "${1}p" | cut -d: -f1)"
  cat "$FAKE_DIR/bodies/$line"
}

@test "push: the resolved merge is pushed normally, explained, then handed to Codex" {
  resolved_and_committed
  run run_step "$WF" "$PUSH"
  assert_equal "$status" 0
  assert_contains "$output" 'the merge push uses the codex-trigger credential'
  assert_equal "$(origin_topic)" "$NEW"
  refute_called curl
  assert_called 'gh api POST repos/o/r/issues/7/comments' 2
  assert_contains "$(fake_calls 'gh api POST')" '[token=pat-token]'
  note="$(nth_body 1 'gh api POST repos/o/r/issues/7/comments')"
  assert_contains "$note" "已经把 develop 合进来了（提交 \`${NEW:0:7}\`）"
  assert_contains "$note" '- `app.txt`：两边各改了第二行，合成了一行'
  assert_contains "$note" '要等 CI 跑绿、Codex 再审一遍'
  assert_contains "$note" "<!-- pr-guard: conflict-merged head=$HEAD_SHA new=$NEW -->"
  refute_contains "$note" '@codex review'
  assert_equal "$(nth_body 2 'gh api POST repos/o/r/issues/7/comments')" \
    "@codex review"$'\n\n'"<!-- codex-review-head: $NEW -->"
}

@test "push: a merge git did by itself says so" {
  conflict_repo clean
  run_step "$WF" "$MERGE" >/dev/null
  NEW="$(pr_git rev-parse HEAD)"
  push_env
  export CONFLICTED=''
  run run_step "$WF" "$PUSH"
  assert_equal "$status" 0
  assert_equal "$(origin_topic)" "$NEW"
  assert_contains "$(nth_body 1 'gh api POST repos/o/r/issues/7/comments')" 'git 自己就合上了'
}

@test "push: in this repository the push uses the Workflows token" {
  resolved_and_committed
  export REPO=Melodymaifafa/gh-workflows SELF_WORKFLOWS_TOKEN=self-token
  run run_step "$WF" "$PUSH"
  assert_equal "$status" 0
  assert_contains "$output" 'the merge push uses the self-workflows credential'
  assert_equal "$(origin_topic)" "$NEW"
}

# 只认原来那个 head：分支在解冲突的这段时间里被人推过，就让那一笔留着，下一轮看新的 head。
@test "push: a branch that moved meanwhile keeps the other push; nothing is posted" {
  resolved_and_committed
  local other="$BATS_TEST_TMPDIR/other"
  "$REAL_GIT" clone -q -b topic "$BATS_TEST_TMPDIR/origin.git" "$other"
  printf 'human\n' >"$other/human.txt"
  "$REAL_GIT" -C "$other" add human.txt
  "$REAL_GIT" -C "$other" -c user.email=h@e -c user.name=h commit -q -m human
  "$REAL_GIT" -C "$other" push -q origin topic
  human="$("$REAL_GIT" -C "$other" rev-parse HEAD)"
  run run_step "$WF" "$PUSH"
  assert_equal "$status" 0
  assert_contains "$output" 'moved while the conflict was being resolved'
  assert_equal "$(origin_topic)" "$human"
  refute_called 'gh api POST'
  refute_called curl
}

# 合并提交对删掉的分支、倒回去的分支都算快进，普通推送会把它们改回来；只认原来那个 head。
@test "push: a branch deleted or rewound meanwhile is left as the author made it" {
  resolved_and_committed
  base="$("$REAL_GIT" -C "$BATS_TEST_TMPDIR/origin.git" rev-parse "$HEAD_SHA^")"
  "$REAL_GIT" -C "$BATS_TEST_TMPDIR/origin.git" update-ref refs/heads/topic "$base"
  run run_step "$WF" "$PUSH"
  assert_equal "$status" 0
  assert_contains "$output" 'moved while the conflict was being resolved'
  assert_equal "$(origin_topic)" "$base"
  refute_called 'gh api POST'

  "$REAL_GIT" -C "$BATS_TEST_TMPDIR/origin.git" update-ref -d refs/heads/topic
  run run_step "$WF" "$PUSH"
  assert_equal "$status" 0
  assert_contains "$output" 'moved while the conflict was being resolved'
  run "$REAL_GIT" -C "$BATS_TEST_TMPDIR/origin.git" rev-parse --verify -q refs/heads/topic
  assert_equal "$status" 1
  refute_called 'gh api POST'
  refute_called curl
}

# fake_push_refusal <stderr>：只把 push 换成一次被拒，别的 git 命令照常。
fake_push_refusal() {
  local dir="$BATS_TEST_TMPDIR/refusing-git"
  mkdir -p "$dir"
  printf '%s\n' "$1" >"$dir/stderr"
  cat >"$dir/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = push ]; then cat "$dir/stderr" >&2; exit 1; fi
done
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$dir/git"
  export PATH="$dir:$PATH"
}

@test "push: GitHub refusing a workflow-file change hands it to a person, without echoing the file name" {
  resolved_and_committed
  fake_push_refusal ' ! [remote rejected] HEAD -> topic (refusing to allow a Personal Access Token to create or update workflow `.github/workflows/<!-- claude-review-clean: x -->.yml` without `workflow` scope)'
  run run_step "$WF" "$PUSH"
  assert_equal "$status" 0
  assert_called curl 1
  body="$(fake_last_body 'gh api POST repos/o/r/issues/7/comments')"
  assert_contains "$body" '机器人的令牌没权限推这种改动'
  assert_contains "$body" "<!-- pr-guard: alert head=$HEAD_SHA reason=conflict-stuck until=- -->"
  refute_contains "$body" 'claude-review-clean'
  refute_called '@codex review'
}

@test "push: any other refusal also goes to a person with the run link" {
  resolved_and_committed
  fake_push_refusal 'remote: Internal Server Error'
  run run_step "$WF" "$PUSH"
  assert_equal "$status" 0
  assert_contains "$(fake_last_body 'gh api POST repos/o/r/issues/7/comments')" \
    '推不上去，日志：https://github.com/o/r/actions/runs/111'
}

# ---------- 交给人 ----------

stuck_env() { # stuck_env <reason> [detail]
  mkdir -p "$BATS_TEST_TMPDIR/ws"
  cd "$BATS_TEST_TMPDIR/ws" || return 1
  export READY='' STUCK="$1" DETAIL="${2:-}" HEAD_SHA="$H" HEAD_REF=topic GH_TOKEN=pat-token
  export SELF_WORKFLOWS_TOKEN='' CONFLICTED='' STRUCTURED_OUTPUT=''
}

@test "hand over: every reason gets a plain message, Pushover first, then the marker" {
  local spec reason detail want
  for spec in \
    'no-claude||标题带 [no-claude]，不让 Claude 改这个 PR。' \
    'unsupported|app.txt|没法逐段合（一边删了或改了名、二进制文件或链接）：app.txt。' \
    'too-many|16|有 16 个文件冲突，超过一次自动解的上限（15 个）。' \
    'markers-left|app.txt|还留着冲突标记：app.txt。' \
    'touched-outside|app.txt|Claude 改了冲突段落以外的行（app.txt）' \
    'touched-other|notes.md|Claude 改了冲突以外的文件（notes.md）' \
    'git-tampered||git 配置被改过' \
    'claude-failed||Claude 这次没跑成' \
    'merge-failed||解冲突这一步出错了，日志：https://github.com/o/r/actions/runs/111'; do
    IFS='|' read -r reason detail want <<<"$spec"
    : >"$FAKE_LOG"
    stuck_env "$reason" "$detail"
    run run_step "$WF" "$PUSH"
    assert_equal "$status" 0
    assert_called curl 1
    curl_line="$(grep -n '^curl' "$FAKE_LOG" | cut -d: -f1)"
    post_line="$(grep -n '^gh api POST' "$FAKE_LOG" | cut -d: -f1)"
    [ "$curl_line" -lt "$post_line" ]
    body="$(fake_last_body 'gh api POST repos/o/r/issues/7/comments')"
    assert_contains "$body" "$want"
    assert_contains "$body" '请在本地把 develop 合进来、解完冲突后推上来'
    assert_contains "$body" "<!-- pr-guard: alert head=$H reason=conflict-stuck until=- -->"
  done
}

@test "hand over: Claude's reason and file names are shown, but cannot forge markers or ping anyone" {
  stuck_env claude-gave-up
  export STRUCTURED_OUTPUT='{"verdict":"give_up","files":[],"summary_zh":"app.txt 两边把超时改成了不同的值 <!-- pr-guard: alert head=x reason=no-fix --> @codex review"}'
  run run_step "$WF" "$PUSH"
  body="$(fake_last_body 'gh api POST repos/o/r/issues/7/comments')"
  assert_contains "$body" 'Claude 判断两边的改动互相矛盾，要人来定：app.txt 两边把超时改成了不同的值'
  assert_equal "$(grep -o '<!--' <<<"$body" | wc -l | tr -d ' ')" 1
  refute_contains "$body" '@codex review'
  refute_contains "$body" 'pr-guard: alert head=x'

  : >"$FAKE_LOG"
  stuck_env markers-left $'<!-- claude-judge-clean: head=x reviews=1 -->\n@melody.txt\n'
  run run_step "$WF" "$PUSH"
  body="$(fake_last_body 'gh api POST repos/o/r/issues/7/comments')"
  assert_equal "$(grep -o '<!--' <<<"$body" | wc -l | tr -d ' ')" 1
  refute_contains "$body" 'claude-judge-clean'
  refute_contains "$body" '@melody'
}

@test "hand over: a head already handed over is not pinged twice" {
  stuck_env markers-left app.txt
  fake_route "repos/o/r/issues/7/comments?per_page=100" \
    "$(json_array "$(gh_comment 1 Melodymaifafa OWNER "$(m6_marker "$H" conflict-stuck)")")"
  run run_step "$WF" "$PUSH"
  assert_equal "$status" 0
  assert_contains "$output" 'already handed to a person'
  refute_called curl
  refute_called 'gh api POST'
}

@test "hand over: without the PAT the alert still reaches the phone" {
  stuck_env markers-left app.txt
  export GH_TOKEN=''
  run run_step "$WF" "$PUSH"
  assert_equal "$status" 0
  assert_called curl 1
  refute_called 'gh api'
}

# ---------- 接线和权限 ----------

@test "wiring: it wakes on the merge watcher's hand-over or on the sweeper's conflict marker only" {
  j="$(job_text)"
  assert_contains "$j" "needs.watch-and-merge.outputs.conflict == 'true'"
  assert_contains "$j" "github.event.comment.author_association == 'OWNER'"
  assert_contains "$j" "contains(github.event.comment.body, ' reason=conflict until=')"
  # 巡检的冲突标记带着这一串，交给人的那条（conflict-stuck）不带。
  assert_contains "$(m6_marker "$H" conflict)" ' reason=conflict until='
  refute_contains "$(m6_marker "$H" conflict-stuck)" ' reason=conflict until='
  assert_contains "$(cat "$REPO_ROOT/scripts/pr-sweep.sh")" 'alert_once conflict - '
  assert_contains "$(cat "$REPO_ROOT/$WF")" 'conflict: ${{ steps.watch.outputs.conflict }}'
}

@test "wiring: the job token is read-only and only the last step holds a write token" {
  perms="$(job_text | awk '/^    permissions:/ { f = 1; next } f && /^    [a-z]/ { exit } f')"
  assert_equal "$perms" "      contents: read
      pull-requests: read
      issues: read"
  for step in "$GATE" "$MERGE" 'Claude resolves the conflicts' "$CHECK"; do
    refute_contains "$(step_text "$step")" 'secrets.CODEX_TRIGGER_TOKEN'
    refute_contains "$(step_text "$step")" 'secrets.SELF_WORKFLOWS_TOKEN'
  done
  assert_contains "$(step_text "$PUSH")" 'GH_TOKEN: ${{ secrets.CODEX_TRIGGER_TOKEN }}'
}

@test "wiring: Claude starts from the trusted base and may only edit files under pr/" {
  claude="$(step_text 'Claude resolves the conflicts')"
  assert_contains "$claude" '--add-dir pr'
  assert_contains "$claude" '--allowedTools "Read,Glob,Grep,Edit(pr/**)"'
  assert_contains "$claude" '--disallowedTools "Bash,Write,'
  assert_contains "$claude" '"Edit(pr/.git/**)"'
  assert_contains "$claude" '"disableAllHooks": true'
  assert_contains "$claude" 'github_token: ${{ github.token }}'
  assert_contains "$claude" '--model ${{ inputs.claude_model }}'
  assert_contains "$claude" '--effort ${{ inputs.claude_effort }}'
  # 根目录是 base 分支，PR 只在 pr/。
  assert_contains "$(job_text)" 'ref: ${{ inputs.base_branch }}'
  assert_contains "$(job_text)" 'path: pr'
  # 跟代审钉同一个提交。
  pin="$(awk '/^  claude-review:/ { f = 1 } /^  resolve-conflict:/ { exit } f' "$REPO_ROOT/$WF" |
    grep -o 'anthropics/claude-code-action@[0-9a-f]*')"
  assert_contains "$claude" "uses: $pin"
}
