#!/usr/bin/env bats
# PR 巡检（scripts/pr-sweep.sh + pr-sweeper.yml 的 run 块）。假 gh 回放 PR 状态，断言它写了什么。

load test_helper/common

H=1a7e81f6b5f27f0a1dbc33c6fafda1bb86f1483d
OTHER=9b14fe3aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
R=Melodymaifafa/private-caller
SWEEPER=.github/workflows/pr-sweeper.yml
# private-caller 是私有仓库：公开日志里只能出现这个标签。
LABEL="repo-$(printf '%s' "$R" | openssl dgst -sha256 -hmac owner-pat | awk '{print $NF}' | cut -c1-8)"
PUB=Melodymaifafa/gh-workflows

setup() {
  setup_fake_env
  export OWNER=Melodymaifafa SWEEP_MODE=live ONLY_REPOS=private-caller GH_TOKEN=owner-pat
  NOW_EPOCH="$(jq -n '"2026-09-18T12:00:00Z" | fromdateiso8601')"
  export NOW_EPOCH
  unset PUSHOVER_TOKEN PUSHOVER_USER SWEEP_READ_TOKEN
  fake_route "user/repos?affiliation=owner&per_page=100" sweep/user-repos.json
  stub "$R" "$(stub_yaml develop)"
  comments
  reviews
}

WF=.github/workflows
# stub_yaml [base_branch 那一行]：合并调用桩；不给参数就不写 base_branch。
stub_yaml() {
  printf '%s\n' 'name: Merge after clean Codex review' 'on:' '  issue_comment:' '    types: [created]' \
    'jobs:' '  merge:' '    uses: Melodymaifafa/gh-workflows/.github/workflows/codex-approved-merge.yml@v1' '    with:'
  [ "$#" = 0 ] || printf '      base_branch: %s\n' "$1"
  printf '%s\n' '    secrets: inherit'
}
# 内联副本：同名文件但没有共享 uses: 行。
INLINE_YAML="name: Merge after clean Codex review
jobs:
  watch:
    if: github.event.pull_request.base.ref == 'develop'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5"
# stub <owner/名> <内容> [文件名]（顺带清掉之前 stub_fail 留下的失败）
stub() {
  local route="repos/$1/contents/$WF/${3:-codex-approved-merge.yml}"
  rm -f "$FAKE_GH_DIR/api/GET/$(fake_route_key "$route").exit"
  fake_route "$route" "$2"
}
# stub_fail <owner/名> <HTTP 状态> [文件名]
stub_fail() {
  fake_route_fail "repos/$1/contents/$WF/${3:-codex-approved-merge.yml}" 1 "{\"message\":\"x\",\"status\":\"$2\"}"
}
# no_stub <owner/名>：两个文件都 404。
no_stub() { stub_fail "$1" 404; stub_fail "$1" 404 self-codex-approved-merge.yml; }
# 直接跑脚本里那个真函数（抠出来，不复制）。
load_integration_base() { eval "$(sed -n '/^integration_base() {$/,/^}$/p' "$REPO_ROOT/scripts/pr-sweep.sh")"; }

# ago <分钟> → NOW_EPOCH 之前那么多分钟的 ISO 时间
ago() { jq -nr --argjson t "$((NOW_EPOCH - $1 * 60))" '$t | todate'; }

# pr_json <number> <mergeable_state> <updated 分钟前> [head] [base] [draft] [title] [head repo]
pr_json() {
  jq -n --argjson n "$1" --arg ms "$2" --arg u "$(ago "$3")" --arg h "${4:-$H}" --arg b "${5:-develop}" \
    --argjson d "${6:-false}" --arg t "${7:-feat: something}" --arg hr "${8:-$R}" --arg r "$R" '{
      number: $n, state: "open", draft: $d, title: $t, merged: false, mergeable_state: $ms,
      updated_at: $u, html_url: "https://github.com/\($r)/pull/\($n)",
      head: {sha: $h, repo: {full_name: $hr}}, base: {ref: $b, repo: {full_name: $r}}
    }'
}

# repo_pr <owner/名> <number> <mergeable_state> <updated 分钟前> [base]：别的仓库的 PR
repo_pr() {
  pr_json "$2" "$3" "$4" "$H" "${5:-develop}" | jq --arg r "$1" \
    '.base.repo.full_name = $r | .head.repo.full_name = $r | .html_url = "https://github.com/\($r)/pull/\(.number)"'
}

# one_pr <mergeable_state> <updated 分钟前> [base]：private-caller 只有 PR #7
one_pr() {
  local pr; pr="$(pr_json 7 "$1" "$2" "$H" "${3:-develop}")"
  fake_route "repos/$R/pulls?state=open&per_page=100" "$(json_array "$pr")"
  fake_route "repos/$R/pulls/7" "$pr"
}

comments() { fake_route "repos/$R/issues/7/comments?per_page=100" "$(json_array "$@")"; }
reviews() { fake_route "repos/$R/pulls/7/reviews?per_page=100" "$(json_array "$@")"; }
owner_comment() { gh_comment "$1" Melodymaifafa OWNER "$2" "$(ago "$3")"; }
alert_comment() { gh_comment "$1" 'github-actions[bot]' NONE "告警。"$'\n\n'"$(m6_marker "$H" "$2" "${3:--}")" "$(ago "${4:-120}")"; }
kick_comment() { owner_comment "$1" "$(m1_body "$H" kick)" "$2"; }
codex_findings() { gh_review "${1:-4863267293}" 'chatgpt-codex-connector[bot]' NONE "${2:-$H}" '### 💡 Codex Review' "$(ago "${3:-180}")"; }
m5_review() { gh_review "$1" Melodymaifafa OWNER "$H" "🤖 巡检：…"$'\n'"<!-- fix-retry: head=$H review=4863267293 -->" "$(ago "$2")"; }

sweep() { run bash "$REPO_ROOT/scripts/pr-sweep.sh"; }

KICK_BODY="@codex review

<!-- codex-review-head: $H -->
<!-- pr-sweeper: kick -->"

refute_writes() {
  refute_called "gh api POST"
  refute_called "gh api PATCH"
  refute_called "gh api PUT"
  refute_called "gh pr"
  refute_called "curl"
}

# ── 规则 5：重新请求审查 ──

@test "backlog: a PR with only a Codex quota comment gets kicked with the exact M1 body" {
  one_pr clean 900
  comments "$(cat "$FIXTURES_DIR/codex/quota-comment.json")"
  sweep
  assert_equal "$status" 0
  assert_called "gh api POST repos/$R/issues/7/comments" 1
  assert_called "[token=owner-pat]"
  assert_equal "$(fake_last_body "gh api POST repos/$R/issues/7/comments")" "$KICK_BODY"
  assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" "kicked $LABEL"
}

@test "an unreferenced head is kicked after 30 idle minutes, not before" {
  one_pr clean 29
  sweep
  refute_writes
  one_pr clean 31
  sweep
  assert_called "gh api POST repos/$R/issues/7/comments" 1
}

@test "a referenced head (OWNER M4) waits for 60 idle minutes" {
  one_pr clean 200
  comments "$(owner_comment 1 "$(m4_body "$H")" 45)"
  sweep
  refute_writes
  comments "$(owner_comment 1 "$(m4_body "$H")" 61)"
  sweep
  assert_called "gh api POST repos/$R/issues/7/comments" 1
}

@test "M1, M2 and M3 for the head also count as references" {
  one_pr clean 200
  comments "$(owner_comment 1 "$(m1_body "$H" 2)" 45)"
  sweep
  refute_writes
  comments "$(gh_comment 1 'github-actions[bot]' NONE "🤖 Codex 这次审不了（额度用完/没回应），换 Claude 代审。
<!-- pr-guard: fallback head=$H reason=silent -->" "$(ago 45)")"
  sweep
  refute_writes
}

@test "markers for another head do not make this head referenced" {
  one_pr clean 200
  comments "$(owner_comment 1 "$(m4_body "$OTHER")" 45)"
  sweep
  assert_called "gh api POST repos/$R/issues/7/comments" 1
}

@test "kicks stop at 3 per head, 60 minutes apart, then one stalled alert" {
  one_pr clean 300
  comments "$(kick_comment 1 200)" "$(kick_comment 2 130)"
  sweep
  assert_called "gh api POST repos/$R/issues/7/comments" 1
  assert_equal "$(fake_last_body "gh api POST")" "$KICK_BODY"

  : >"$FAKE_LOG"
  comments "$(kick_comment 1 200)" "$(kick_comment 2 130)" "$(kick_comment 3 61)"
  export PUSHOVER_TOKEN=t PUSHOVER_USER=u
  sweep
  assert_called "curl" 1
  assert_called "gh api POST repos/$R/issues/7/comments" 1
  body="$(fake_last_body "gh api POST repos/$R/issues/7/comments")"
  assert_contains "$body" "<!-- pr-guard: alert head=$H reason=stalled until=- -->"
  refute_contains "$body" "@codex review"
}

@test "after the stalled alert: one kick per day for 7 days, then nothing" {
  one_pr clean 2000
  local k=("$(kick_comment 1 5000)" "$(kick_comment 2 4900)" "$(kick_comment 3 4800)")
  # 停了 1 小时：还不到一天，不踢。
  comments "${k[@]}" "$(alert_comment 9 stalled - 60)"
  sweep
  refute_writes
  # 停了 2 天、上次踢 25 小时前：踢一次。
  comments "${k[@]}" "$(alert_comment 9 stalled - 2880)" "$(kick_comment 4 1500)"
  sweep
  assert_called "gh api POST repos/$R/issues/7/comments" 1
  assert_equal "$(fake_last_body "gh api POST")" "$KICK_BODY"
  # 停了 8 天：不再踢。
  : >"$FAKE_LOG"
  comments "${k[@]}" "$(alert_comment 9 stalled - 11520)"
  sweep
  refute_writes
}

@test "a merged PR is never kicked" {
  pr="$(pr_json 7 clean 300 | jq '.merged = true')"
  fake_route "repos/$R/pulls?state=open&per_page=100" "$(json_array "$pr")"
  fake_route "repos/$R/pulls/7" "$pr"
  sweep
  refute_writes
}

# ── 规则 1：冲突 ──

@test "backlog: a conflicted PR alerts once, Pushover first, then the marker" {
  one_pr dirty 900
  export PUSHOVER_TOKEN=t PUSHOVER_USER=u
  sweep
  assert_equal "$status" 0
  assert_called "curl" 1
  assert_called "gh api POST repos/$R/issues/7/comments" 1
  curl_line="$(grep -n '^curl' "$FAKE_LOG" | cut -d: -f1)"
  post_line="$(grep -n '^gh api POST' "$FAKE_LOG" | cut -d: -f1)"
  [ "$curl_line" -lt "$post_line" ]
  body="$(fake_last_body "gh api POST repos/$R/issues/7/comments")"
  assert_contains "$body" "<!-- pr-guard: alert head=$H reason=conflict until=- -->"
  assert_contains "$body" "这个 PR 和 develop 有冲突"
  refute_contains "$body" "@codex review"
  refute_contains "$body" "claude-review-clean:"

  # 下一轮：标记已在，什么也不做（也不踢）。
  : >"$FAKE_LOG"
  comments "$(owner_comment 5 "$body" 1)"
  sweep
  refute_writes
}

@test "a Pushover failure posts no marker, so the next sweep retries" {
  one_pr dirty 900
  export PUSHOVER_TOKEN=t PUSHOVER_USER=u
  echo 22 >"$FAKE_GH_DIR/curl.exit"
  sweep
  assert_equal "$status" 0
  assert_called "curl" 1
  refute_called "gh api POST"
}

@test "without Pushover secrets the alert marker is still posted" {
  one_pr dirty 900
  sweep
  refute_called "curl"
  assert_called "gh api POST repos/$R/issues/7/comments" 1
}

# ── 规则 2 / 3：停车、额度 ──

@test "parked heads stop: no-fix, round-cap, and ci while unstable" {
  for r in no-fix round-cap; do
    : >"$FAKE_LOG"
    one_pr clean 900
    comments "$(alert_comment 1 "$r")"
    reviews "$(codex_findings)"
    sweep
    refute_writes
  done
  : >"$FAKE_LOG"
  one_pr unstable 900
  comments "$(alert_comment 1 ci)"
  reviews
  sweep
  refute_writes
}

@test "a ci alert stops parking once CI is green again" {
  one_pr clean 900
  comments "$(alert_comment 1 ci - 600)"
  sweep
  assert_called "gh api POST repos/$R/issues/7/comments" 1
  assert_equal "$(fake_last_body "gh api POST")" "$KICK_BODY"
}

@test "an unexpired until stops; an expired one lets the kick through" {
  one_pr clean 900
  comments "$(alert_comment 1 review-quota "$((NOW_EPOCH + 3600))" 600)"
  sweep
  refute_writes
  comments "$(alert_comment 1 review-quota "$((NOW_EPOCH - 60))" 600)"
  sweep
  assert_called "gh api POST repos/$R/issues/7/comments" 1
}

# ── 规则 4：有意见就重修 ──

@test "a head with Codex findings gets M5 after 60 idle minutes, never a kick" {
  one_pr clean 30
  reviews "$(codex_findings 4863267293 "$H" 30)"
  sweep
  refute_writes

  one_pr clean 61
  reviews "$(codex_findings 4863267293 "$H" 61)"
  sweep
  assert_called "gh api POST repos/$R/pulls/7/reviews" 1
  refute_called "gh api POST repos/$R/issues/7/comments"
  assert_called "event=COMMENT -f commit_id=$H"
  assert_equal "$(fake_last_body "gh api POST repos/$R/pulls/7/reviews")" "🤖 巡检：上次自动修复没完成（一直没有结果），再修一次。
<!-- fix-retry: head=$H review=4863267293 -->"
}

@test "an OWNER M3 counts as findings and is the M5 target when newest" {
  one_pr clean 200
  reviews "$(codex_findings 111 "$H" 300)" \
    "$(gh_review 222 Melodymaifafa OWNER "$H" "$(m3_body "$H")" "$(ago 200)")"
  sweep
  assert_called "gh api POST repos/$R/pulls/7/reviews" 1
  assert_contains "$(fake_last_body "gh api POST")" "<!-- fix-retry: head=$H review=222 -->"
}

@test "Codex findings on an older commit do not count for this head" {
  one_pr clean 200
  reviews "$(codex_findings 4863267293 "$OTHER" 300)"
  sweep
  refute_called "gh api POST repos/$R/pulls/7/reviews"
  assert_equal "$(fake_last_body "gh api POST")" "$KICK_BODY"
}

@test "a passed fix-quota until retries at once and names the reason" {
  one_pr clean 5
  reviews "$(codex_findings 4863267293 "$H" 600)"
  comments "$(alert_comment 1 fix-quota "$((NOW_EPOCH - 60))" 5)"
  sweep
  assert_called "gh api POST repos/$R/pulls/7/reviews" 1
  assert_contains "$(fake_last_body "gh api POST")" "（额度用完，现已恢复）"
}

@test "an until that passed before the last M5 does not skip the idle wait" {
  one_pr clean 10
  reviews "$(codex_findings 4863267293 "$H" 600)" "$(m5_review 5 10)"
  comments "$(alert_comment 1 fix-quota "$((NOW_EPOCH - 3000))" 500)"
  sweep
  refute_writes
}

@test "two counted failed retries: one retry-exhausted alert after 60 idle minutes, then parked" {
  export PUSHOVER_TOKEN=t PUSHOVER_USER=u
  reviews "$(codex_findings 4863267293 "$H" 600)" "$(m5_review 5 400)" "$(m5_review 6 200)"
  comments "$(alert_comment 1 fix-failed - 300)"
  # 第二次重修刚结束不久：先等。
  one_pr clean 30
  sweep
  refute_writes

  one_pr clean 200
  sweep
  refute_called "gh api POST repos/$R/pulls/7/reviews"
  assert_called "curl" 1
  assert_called "gh api POST repos/$R/issues/7/comments" 1
  assert_equal "$(fake_last_body "gh api POST")" "🤖 自动修复重试 2 次还是没完成，已停。你来点 Merge 或关掉；推新提交会重新开始。

<!-- pr-guard: alert head=$H reason=retry-exhausted until=- -->"

  : >"$FAKE_LOG"
  comments "$(alert_comment 1 fix-failed - 300)" "$(alert_comment 2 retry-exhausted - 100)"
  sweep
  refute_writes
}

@test "a second quota hit waits for the new until and does not burn a retry" {
  one_pr clean 70
  local first m5 quiet
  first="$(alert_comment 1 fix-quota "$((NOW_EPOCH - 250 * 60))" 300)"
  m5="$(m5_review 5 240)"
  # M5 #1 之后又撞额度：iterate 补了一条不推送的新 until。
  quiet() { gh_comment 2 'github-actions[bot]' NONE "🤖 额度又用完了，改到北京时间 09-18 20:00 后继续（不再重复推送）。"$'\n\n'"$(m6_marker "$H" fix-quota "$1")" "$(ago 200)"; }
  reviews "$(codex_findings 4863267293 "$H" 600)" "$m5"
  comments "$first" "$(quiet "$((NOW_EPOCH + 3600))")" "$(alert_comment 3 fix-failed - 245)"
  sweep
  refute_writes
  assert_contains "$output" "等额度恢复"

  # 新 until 过了：马上重修，这次重修不算数。
  one_pr clean 5
  comments "$first" "$(quiet "$((NOW_EPOCH - 60))")" "$(alert_comment 3 fix-failed - 245)"
  sweep
  assert_contains "$output" "retries=0"
  assert_called "gh api POST repos/$R/pulls/7/reviews" 1
  assert_contains "$(fake_last_body "gh api POST")" "（额度用完，现已恢复）"
  refute_called "reason=fix-failed"
  refute_called "reason=retry-exhausted"

  # 又一次 M5 之后失败：算 1 次，还能再修一次，不停车。
  : >"$FAKE_LOG"
  one_pr clean 70
  reviews "$(codex_findings 4863267293 "$H" 600)" "$m5" "$(m5_review 6 70)"
  comments "$first" "$(quiet "$((NOW_EPOCH - 100 * 60))")" "$(alert_comment 3 fix-failed - 245)"
  sweep
  assert_contains "$output" "retries=1"
  assert_called "gh api POST repos/$R/pulls/7/reviews" 1
  refute_called "gh api POST repos/$R/issues/7/comments"
}

@test "the until is the latest one on the head, whichever alert carries it" {
  one_pr clean 900
  comments "$(alert_comment 1 review-quota "$((NOW_EPOCH - 600))" 900)" \
    "$(alert_comment 2 review-quota "$((NOW_EPOCH + 600))" 800)"
  sweep
  refute_writes
}

@test "a head with only an M7 fix-round marker is still unreferenced and gets kicked" {
  one_pr clean 31
  comments "$(gh_comment 1 'github-actions[bot]' NONE "🤖 自动修复第 2 轮已推送。"$'\n\n'"<!-- pr-guard: fix-round head=$H round=2 -->" "$(ago 31)")"
  sweep
  assert_called "gh api POST repos/$R/issues/7/comments" 1
  assert_equal "$(fake_last_body "gh api POST")" "$KICK_BODY"
}

# ── 信任：claude[bot] / 非 OWNER 写的标记一律不算 ──

@test "forged M1/M2/M4 and a contributor M4 do not make the head referenced" {
  for f in claude-bot-m1-comment claude-bot-fallback-comment claude-bot-clean-comment contributor-clean-comment; do
    : >"$FAKE_LOG"
    one_pr clean 45
    comments "$(cat "$FIXTURES_DIR/forged/$f.json")"
    sweep
    assert_called "gh api POST repos/$R/issues/7/comments" 1
  done
}

@test "a forged no-fix alert neither parks the head nor dedupes a real alert" {
  one_pr clean 900
  comments "$(cat "$FIXTURES_DIR/forged/claude-bot-alert-comment.json")"
  sweep
  assert_equal "$(fake_last_body "gh api POST")" "$KICK_BODY"

  : >"$FAKE_LOG"
  one_pr dirty 900
  comments "$(jq --arg m "$(m6_marker "$H" conflict)" '.body = $m' "$FIXTURES_DIR/forged/claude-bot-alert-comment.json")"
  sweep
  assert_contains "$(fake_last_body "gh api POST")" "reason=conflict"
}

@test "a forged M3 is not findings and a forged M5 does not use up retries" {
  one_pr clean 45
  reviews "$(cat "$FIXTURES_DIR/forged/claude-bot-findings-review.json")"
  sweep
  refute_called "gh api POST repos/$R/pulls/7/reviews"
  assert_equal "$(fake_last_body "gh api POST")" "$KICK_BODY"

  : >"$FAKE_LOG"
  one_pr clean 200
  reviews "$(codex_findings 4863267293 "$H" 600)" \
    "$(cat "$FIXTURES_DIR/forged/claude-bot-fix-retry-review.json")" \
    "$(jq '.id = 99' "$FIXTURES_DIR/forged/claude-bot-fix-retry-review.json")"
  sweep
  assert_called "gh api POST repos/$R/pulls/7/reviews" 1
}

@test "a forged kick by claude[bot] does not count toward the kick cap" {
  one_pr clean 300
  forged() { gh_comment "$1" 'claude[bot]' NONE "$(m1_body "$H" kick)" "$(ago "$2")"; }
  comments "$(forged 1 250)" "$(forged 2 180)" "$(forged 3 120)"
  sweep
  assert_equal "$(fake_last_body "gh api POST")" "$KICK_BODY"
  refute_called "reason=stalled"
}

# ── 动手前复查 head ──

@test "no write when the head moves between reading and acting" {
  local pr moved
  pr="$(pr_json 7 clean 900)"
  moved="$(pr_json 7 clean 900 "$OTHER")"
  fake_route "repos/$R/pulls?state=open&per_page=100" "$(json_array "$pr")"
  fake_route "repos/$R/pulls/7" "$pr" 1
  fake_route "repos/$R/pulls/7" "$moved" 2
  sweep
  assert_equal "$status" 0
  refute_writes
}

# ── dry / off ──

@test "dry mode writes would-lines to the summary and performs zero writes" {
  export SWEEP_MODE=dry PUSHOVER_TOKEN=t PUSHOVER_USER=u
  local conflict kickme fixme offbase
  conflict="$(pr_json 1 dirty 900)"
  kickme="$(pr_json 7 clean 900)"
  fixme="$(pr_json 8 clean 900)"
  offbase="$(pr_json 9 clean 900 "$H" main)"
  fake_route "repos/$R/pulls?state=open&per_page=100" "$(json_array "$conflict" "$kickme" "$fixme" "$offbase")"
  fake_route "repos/$R/pulls/1" "$conflict"
  fake_route "repos/$R/pulls/7" "$kickme"
  fake_route "repos/$R/pulls/8" "$fixme"
  fake_route "repos/$R/pulls/9" "$offbase"
  for n in 1 8 9; do
    fake_route "repos/$R/issues/$n/comments?per_page=100" '[]'
    fake_route "repos/$R/pulls/$n/reviews?per_page=100" '[]'
  done
  fake_route "repos/$R/pulls/8/reviews?per_page=100" "$(json_array "$(codex_findings)")"
  sweep
  assert_equal "$status" 0
  refute_writes
  summary="$(cat "$GITHUB_STEP_SUMMARY")"
  assert_contains "$summary" "would alert $LABEL reason=conflict"
  assert_contains "$summary" "would kick $LABEL"
  assert_contains "$summary" "would retry fix $LABEL"
  assert_contains "$summary" "would alert $LABEL reason=unwatched"
}

@test "SWEEP_MODE off or unset does nothing at all" {
  export SWEEP_MODE=off
  sweep
  assert_equal "$status" 0
  assert_equal "$(fake_calls)" ""
  unset SWEEP_MODE
  sweep
  assert_equal "$status" 0
  assert_equal "$(fake_calls)" ""
}

# ── 仓库、PR 筛选 ──

@test "discovery: owned, unarchived repos of any default branch; drafts, forks and opt-outs are skipped" {
  export ONLY_REPOS=""
  fake_route "repos/Melodymaifafa/gh-workflows/pulls?state=open&per_page=100" '[]'
  fake_route "repos/Melodymaifafa/main-default/pulls?state=open&per_page=100" '[]'
  fake_route "repos/$R/pulls?state=open&per_page=100" "$(json_array \
    "$(pr_json 3 clean 900 "$H" develop true)" \
    "$(pr_json 4 clean 900 "$H" develop false '[no-claude] wip')" \
    "$(pr_json 5 clean 900 "$H" develop false '[no-codex-merge] x')" \
    "$(pr_json 6 clean 900 "$H" develop false 'x' someone/fork)")"
  sweep
  assert_equal "$status" 0
  assert_called "gh api GET repos/Melodymaifafa/gh-workflows/pulls"
  assert_called "gh api GET repos/Melodymaifafa/main-default/pulls"
  refute_called "old-archived"
  refute_called "someone-elses"
  refute_called "repos/$R/pulls/"
  # 没有要管的 PR：不读调用桩。
  refute_called "/contents/"
  refute_writes
}

@test "backlog shape: quota-only PR kicked, conflicted PR alerted once, empty repo costs one list call" {
  export ONLY_REPOS="private-caller, main-default"
  local quota conflicted
  quota="$(pr_json 7 clean 900)"
  conflicted="$(pr_json 1 dirty 70000 "$OTHER")"
  fake_route "repos/$R/pulls?state=open&per_page=100" "$(json_array "$quota" "$conflicted")"
  fake_route "repos/$R/pulls/7" "$quota"
  fake_route "repos/$R/pulls/1" "$conflicted"
  comments "$(cat "$FIXTURES_DIR/codex/quota-comment.json")"
  fake_route "repos/$R/issues/1/comments?per_page=100" '[]'
  fake_route "repos/$R/pulls/1/reviews?per_page=100" "$(json_array "$(codex_findings 1 "$OTHER" 70000)")"
  fake_route "repos/Melodymaifafa/main-default/pulls?state=open&per_page=100" '[]'
  sweep
  assert_equal "$status" 0
  assert_called "main-default" 1
  refute_called "main-default/contents"
  assert_called "gh api POST" 2
  assert_equal "$(fake_last_body "gh api POST repos/$R/issues/7/comments")" "$KICK_BODY"
  assert_contains "$(fake_last_body "gh api POST repos/$R/issues/1/comments")" \
    "<!-- pr-guard: alert head=$OTHER reason=conflict until=- -->"
}

@test "one broken PR does not stop the others, and the sweep exits 1" {
  local bad good
  bad="$(pr_json 1 clean 900)"
  good="$(pr_json 7 clean 900)"
  fake_route "repos/$R/pulls?state=open&per_page=100" "$(json_array "$bad" "$good")"
  fake_route "repos/$R/pulls/1" "$bad"
  fake_route "repos/$R/pulls/7" "$good"
  # PR #1 没有评论 fixture → 假 gh exit 97
  sweep
  assert_equal "$status" 1
  assert_contains "$output" "$LABEL 巡检出错"
  assert_called "gh api POST repos/$R/issues/7/comments" 1
}

@test "invariant: no sweeper alert or retry body contains trigger text" {
  export PUSHOVER_TOKEN=t PUSHOVER_USER=u
  one_pr dirty 900
  sweep
  one_pr clean 200
  reviews "$(codex_findings)" "$(m5_review 5 400)" "$(m5_review 6 300)"
  sweep
  reviews "$(codex_findings)"
  sweep
  comments "$(kick_comment 1 300)" "$(kick_comment 2 200)" "$(kick_comment 3 100)"
  reviews
  sweep
  comments
  one_pr clean 900 main
  sweep
  no_stub "$R"
  one_pr clean 900
  sweep
  local line body n=0
  while IFS= read -r line; do
    n=$((n + 1))
    case "$line" in *"gh api POST"*|curl*) ;; *) continue ;; esac
    body="$(cat "$FAKE_DIR/bodies/$n")"
    case "$body" in *"pr-guard: alert"*|*"fix-retry:"*|"") ;; *) continue ;; esac
    refute_contains "$body" "@codex review"
    refute_contains "$body" "claude-review-clean:"
  done <"$FAKE_LOG"
  assert_contains "$(fake_all_bodies)" "reason=conflict"
  assert_contains "$(fake_all_bodies)" "reason=retry-exhausted"
  assert_contains "$(fake_all_bodies)" "fix-retry: head=$H"
  assert_contains "$(fake_all_bodies)" "reason=stalled"
  assert_equal "$(fake_count "reason=unwatched")" 2
}

# ── 集成分支：从调用桩读 base_branch ──

@test "integration_base: 0 with the stub's base; 3 for 404 or an inline copy; 4 for 403, other errors or a bad value" {
  load_integration_base
  run integration_base "$R"
  assert_equal "$status" 0
  assert_equal "$output" develop

  no_stub "$R"
  run integration_base "$R"
  assert_equal "$status" 3

  stub "$R" "$INLINE_YAML"
  run integration_base "$R"
  assert_equal "$status" 3

  : >"$FAKE_LOG"
  stub_fail "$R" 403
  run integration_base "$R"
  assert_equal "$status" 4
  # 403 就停，不再去试第二个文件。
  refute_called "self-codex-approved-merge.yml"

  stub_fail "$R" 502
  run integration_base "$R"
  assert_equal "$status" 4
  # 没有 JSON 的错误（网络断了之类）
  rm -f "$FAKE_GH_DIR/api/GET/$(fake_route_key "repos/$R/contents/$WF/codex-approved-merge.yml").json"
  run integration_base "$R"
  assert_equal "$status" 4

  local bad
  # shellcheck disable=SC2016  # 字面量 ${{ }}
  # `-` 是主循环里「没接入」的占位值，必须读不进来。
  for bad in '${{ vars.BASE }}' 'feat/../x' 'develop#x' '"a b"' '' "$(printf 'a%.0s' {1..101})" \
    - . / -x a//b feat/ x. feat/.x; do
    stub "$R" "$(stub_yaml "$bad")"
    run integration_base "$R"
    assert_equal "$status" 4
  done
}

@test "integration_base: quoted values, trailing comments and a missing base_branch parse" {
  load_integration_base
  local line want
  while IFS='|' read -r line want; do
    stub "$R" "$(stub_yaml "$line")"
    run integration_base "$R"
    assert_equal "$status" 0
    assert_equal "$output" "$want"
  done <<'EOF'
develop|develop
"release/2.0"|release/2.0
'feat/some_x'|feat/some_x
main   # 集成分支|main
"feat/y" # 注释|feat/y
EOF
  stub "$R" "$(stub_yaml)"
  run integration_base "$R"
  assert_equal "$output" develop

  stub "$R" "$(stub_yaml main | sed "s#uses: \(.*\)#uses: '\1'#")"
  run integration_base "$R"
  assert_equal "$output" main
}

@test "SWEEP_READ_TOKEN, when set, reads the caller stub; writes still use GH_TOKEN" {
  export SWEEP_READ_TOKEN=read-pat
  one_pr clean 900
  sweep
  assert_equal "$status" 0
  assert_contains "$(fake_calls "contents/$WF/codex-approved-merge.yml")" "[token=read-pat]"
  assert_contains "$(fake_calls "gh api POST")" "[token=owner-pat]"
  refute_contains "$(fake_calls "gh api POST")" "read-pat"
}

@test "a main-default repo onboarded with base main: its main PR is swept, its develop PR is unwatched" {
  export ONLY_REPOS=main-default
  local M=Melodymaifafa/main-default into_main into_develop
  stub "$M" "$(stub_yaml main)"
  into_main="$(repo_pr "$M" 1 dirty 900 main)"
  into_develop="$(repo_pr "$M" 2 clean 900 develop)"
  fake_route "repos/$M/pulls?state=open&per_page=100" "$(json_array "$into_main" "$into_develop")"
  fake_route "repos/$M/pulls/1" "$into_main"
  fake_route "repos/$M/pulls/2" "$into_develop"
  for n in 1 2; do
    fake_route "repos/$M/issues/$n/comments?per_page=100" '[]'
    fake_route "repos/$M/pulls/$n/reviews?per_page=100" '[]'
  done
  sweep
  assert_equal "$status" 0
  assert_contains "$output" "$M: 集成分支 main"
  assert_contains "$(fake_last_body "gh api POST repos/$M/issues/1/comments")" "这个 PR 和 main 有冲突"
  body="$(fake_last_body "gh api POST repos/$M/issues/2/comments")"
  assert_contains "$body" "只管打向 main 的 PR"
  assert_contains "$body" "reason=unwatched"

  # 冲突解了：打向 main 的 PR 照常叫审。
  : >"$FAKE_LOG"
  into_main="$(repo_pr "$M" 1 clean 900 main)"
  fake_route "repos/$M/pulls?state=open&per_page=100" "$(json_array "$into_main")"
  fake_route "repos/$M/pulls/1" "$into_main"
  sweep
  assert_equal "$(fake_last_body "gh api POST repos/$M/issues/1/comments")" "$KICK_BODY"
}

@test "an unreadable stub falls back to develop-only: develop-default repo swept, main-default skipped, one warning" {
  export ONLY_REPOS="private-caller, main-default"
  local M=Melodymaifafa/main-default into_main
  stub_fail "$R" 403
  stub_fail "$M" 403
  into_main="$(pr_json 2 clean 900 "$H" main)"
  fake_route "repos/$R/pulls?state=open&per_page=100" "$(json_array "$(pr_json 7 clean 900)" "$into_main")"
  fake_route "repos/$R/pulls/7" "$(pr_json 7 clean 900)"
  fake_route "repos/$M/pulls?state=open&per_page=100" "$(json_array "$(repo_pr "$M" 1 clean 900)")"
  sweep
  assert_equal "$status" 0
  # 旧规则：develop 仓库里合进 develop 的照常叫审，别的一概不碰。
  assert_called "gh api POST" 1
  assert_equal "$(fake_last_body "gh api POST repos/$R/issues/7/comments")" "$KICK_BODY"
  refute_called "repos/$R/pulls/2"
  refute_called "repos/$M/pulls/1"
  refute_called "reason=unwatched"
  assert_equal "$(grep -c '::warning::' <<<"$output")" 1
  assert_contains "$output" "::warning::2 个仓库读不到合并调用桩"
  assert_contains "$output" "Contents: Read-only"
  assert_contains "$output" "$LABEL"
  refute_contains "$output" "private-caller"
}

@test "a repo without shared automation: one unwatched alert per head after 60 idle minutes, never a kick or M5" {
  export PUSHOVER_TOKEN=t PUSHOVER_USER=u
  local how
  for how in missing inline; do
    : >"$FAKE_LOG"
    comments
    if [ "$how" = missing ]; then no_stub "$R"; else stub "$R" "$INLINE_YAML"; fi
    reviews "$(codex_findings 4863267293 "$H" 900)"
    one_pr clean 59
    sweep
    assert_equal "$status" 0
    refute_writes

    one_pr clean 900
    sweep
    assert_equal "$status" 0
    assert_called "curl" 1
    assert_called "gh api POST" 1
    curl_line="$(grep -n '^curl' "$FAKE_LOG" | cut -d: -f1)"
    post_line="$(grep -n '^gh api POST' "$FAKE_LOG" | cut -d: -f1)"
    [ "$curl_line" -lt "$post_line" ]
    body="$(fake_last_body "gh api POST repos/$R/issues/7/comments")"
    assert_contains "$body" "没接共享的审查自动化"
    assert_contains "$body" "<!-- pr-guard: alert head=$H reason=unwatched until=- -->"
    refute_contains "$body" "@codex review"

    # 同一个 head：已经空闲够了，但有标记，不再推。
    : >"$FAKE_LOG"
    comments "$(gh_comment 5 Melodymaifafa OWNER "$body" "$(ago 120)")"
    sweep
    refute_writes
  done
}

@test "a PR off the integration branch: one unwatched alert per head, a new head alerts again" {
  one_pr clean 900 main
  sweep
  assert_called "gh api POST" 1
  body="$(fake_last_body "gh api POST repos/$R/issues/7/comments")"
  assert_equal "$body" "🤖 巡检：自动审查和合并只管打向 develop 的 PR，这个 PR 不会有人管。请把 base 改成 develop，或关掉。

<!-- pr-guard: alert head=$H reason=unwatched until=- -->"

  : >"$FAKE_LOG"
  comments "$(gh_comment 5 Melodymaifafa OWNER "$body" "$(ago 120)")"
  sweep
  refute_writes

  # 推了新提交：新 head，再告一次。
  : >"$FAKE_LOG"
  pr="$(pr_json 7 clean 900 "$OTHER" main)"
  fake_route "repos/$R/pulls?state=open&per_page=100" "$(json_array "$pr")"
  fake_route "repos/$R/pulls/7" "$pr"
  sweep
  assert_called "gh api POST" 1
  assert_contains "$(fake_last_body "gh api POST")" "alert head=$OTHER reason=unwatched"
}

@test "unwatched beats conflict and parked: an unwatched, conflicting, parked PR gets only the unwatched alert" {
  local how body
  for how in offbase missing; do
    : >"$FAKE_LOG"
    if [ "$how" = missing ]; then no_stub "$R"; one_pr dirty 900; else stub "$R" "$(stub_yaml develop)"; one_pr dirty 900 main; fi
    comments "$(alert_comment 5 no-fix)"
    sweep
    assert_equal "$status" 0
    assert_called "gh api POST" 1
    body="$(fake_last_body "gh api POST repos/$R/issues/7/comments")"
    assert_contains "$body" "reason=unwatched"
    refute_contains "$body" "冲突"
  done
}

# ── 公开日志不出现私有仓库 ──

@test "private repo: logs and summary show only the opaque label, never the name, PR number or SHA" {
  export PUSHOVER_TOKEN=t PUSHOVER_USER=u
  # 私有仓库的集成分支名也不能进日志。
  local B=feat/secret-branch conflict kickme bad offbase
  stub "$R" "$(stub_yaml "$B")"
  conflict="$(pr_json 1 dirty 900 "$H" "$B")"
  kickme="$(pr_json 7 clean 900 "$H" "$B")"
  bad="$(pr_json 3 clean 900 "$H" "$B")"
  offbase="$(pr_json 4 clean 900 "$H" main)"
  fake_route "repos/$R/pulls?state=open&per_page=100" "$(json_array "$conflict" "$kickme" "$bad" "$offbase")"
  fake_route "repos/$R/pulls/1" "$conflict"
  fake_route "repos/$R/pulls/7" "$kickme"
  fake_route "repos/$R/pulls/3" "$bad"
  fake_route "repos/$R/pulls/4" "$offbase"
  for n in 1 4; do
    fake_route "repos/$R/issues/$n/comments?per_page=100" '[]'
    fake_route "repos/$R/pulls/$n/reviews?per_page=100" '[]'
  done
  # PR #3 没有评论 fixture → 假 gh 报错（报错里带仓库名）
  for mode in dry live; do
    : >"$FAKE_LOG"; : >"$GITHUB_STEP_SUMMARY"
    SWEEP_MODE=$mode run bash "$REPO_ROOT/scripts/pr-sweep.sh"
    assert_equal "$status" 1
    local all; all="$output$(cat "$GITHUB_STEP_SUMMARY")"
    assert_contains "$all" "$LABEL"
    refute_contains "$all" "private-caller"
    refute_contains "$all" "#1"
    refute_contains "$all" "#7"
    refute_contains "$all" "#3"
    refute_contains "$all" "#4"
    refute_contains "$all" "${H:0:7}"
    refute_contains "$all" "secret-branch"
  done
  # Pushover 和 PR 评论是私人通道，照写真名和分支名。
  assert_contains "$(fake_calls curl)" "$R#1"
  assert_contains "$(fake_last_body "gh api POST repos/$R/issues/1/comments")" "这个 PR 和 $B 有冲突"
  assert_contains "$(fake_last_body "gh api POST repos/$R/issues/4/comments")" "把 base 改成 $B"
  assert_equal "$(fake_last_body "gh api POST repos/$R/issues/7/comments")" "$KICK_BODY"

  # 读不到调用桩、没接自动化：日志同样只有标签。
  for setup_stub in "stub_fail $R 403" "no_stub $R"; do
    : >"$FAKE_LOG"; : >"$GITHUB_STEP_SUMMARY"
    $setup_stub
    sweep
    all="$output$(cat "$GITHUB_STEP_SUMMARY")"
    refute_contains "$all" "private-caller"
    refute_contains "$all" "secret-branch"
    refute_contains "$all" "FAKE"
  done

  # 列 PR 失败：只有标签和通用警告。
  : >"$FAKE_LOG"
  fake_route_fail "repos/$R/pulls?state=open&per_page=100" 1 '{"message":"Not Found"}'
  sweep
  assert_contains "$output" "::warning::$LABEL 列 PR 失败"
  refute_contains "$output" "private-caller"
}

@test "public repo: logs and summary may show the name, PR number and SHA" {
  export ONLY_REPOS=gh-workflows
  local pr
  pr="$(pr_json 7 clean 900 | jq --arg r "$PUB" '.base.repo.full_name = $r | .head.repo.full_name = $r')"
  fake_route "repos/$PUB/pulls?state=open&per_page=100" "$(json_array "$pr")"
  fake_route "repos/$PUB/pulls/7" "$pr"
  fake_route "repos/$PUB/issues/7/comments?per_page=100" '[]'
  fake_route "repos/$PUB/pulls/7/reviews?per_page=100" '[]'
  # 本仓库的 codex-approved-merge.yml 是定义本身，调用桩是 self-codex-approved-merge.yml。
  stub "$PUB" "$INLINE_YAML"
  stub "$PUB" "$(stub_yaml develop)" self-codex-approved-merge.yml
  sweep
  assert_equal "$status" 0
  assert_contains "$output" "$PUB: 集成分支 develop"
  assert_contains "$output" "$PUB#7 (${H:0:7}): idle="
  assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" "kicked $PUB#7 (${H:0:7})"
}

# ── pr-sweeper.yml 的 run 块 ──

@test "workflow: SWEEP_MODE resolves to off when unset or unknown; dispatch dry_run downgrades live" {
  unset SWEEP_MODE DRY_RUN
  run run_block "$SWEEPER" "Resolve sweep mode"
  assert_equal "$(step_output mode)" off
  SWEEP_MODE=bogus run run_block "$SWEEPER" "Resolve sweep mode"
  assert_equal "$(step_output mode)" off
  SWEEP_MODE=live DRY_RUN=true run run_block "$SWEEPER" "Resolve sweep mode"
  assert_equal "$(step_output mode)" dry
  SWEEP_MODE=live DRY_RUN='' run run_block "$SWEEPER" "Resolve sweep mode"
  assert_equal "$(step_output mode)" live
  SWEEP_MODE=dry run run_block "$SWEEPER" "Resolve sweep mode"
  assert_equal "$(step_output mode)" dry
}

@test "workflow: the sweep step refuses to run without the PAT" {
  GH_TOKEN="" run run_block "$SWEEPER" "Sweep open PRs"
  assert_equal "$status" 1
  assert_contains "$output" "CODEX_TRIGGER_TOKEN"
}

@test "workflow: the sweep step reads the repos input from the event file, not env" {
  cd "$REPO_ROOT"
  export GITHUB_EVENT_PATH="$BATS_TEST_TMPDIR/event.json"
  echo '{"inputs":{"repos":"private-caller"}}' >"$GITHUB_EVENT_PATH"
  one_pr clean 900
  ONLY_REPOS="" run run_block "$SWEEPER" "Sweep open PRs"
  assert_equal "$status" 0
  refute_called "gh-workflows/pulls"
  assert_called "gh api POST repos/$R/issues/7/comments" 1
  refute_contains "$(sed -n '/- name: Sweep open PRs/,/run: |/p' "$REPO_ROOT/$SWEEPER")" "inputs.repos"
}

@test "workflow: a failed sweep alerts only after a successful previous run" {
  export REPO=Melodymaifafa/gh-workflows PUSHOVER_TOKEN=t PUSHOVER_USER=u RUN_URL=https://x/run/1
  runs="repos/$REPO/actions/workflows/pr-sweeper.yml/runs?status=completed&per_page=1"
  fake_route "$runs" '{"workflow_runs":[{"conclusion":"success"}]}'
  run run_block "$SWEEPER" "Alert when the sweep starts failing"
  assert_equal "$status" 0
  assert_called "curl" 1
  assert_contains "$(fake_last_body curl)" "https://x/run/1"

  : >"$FAKE_LOG"
  fake_route "$runs" '{"workflow_runs":[{"conclusion":"failure"}]}'
  run run_block "$SWEEPER" "Alert when the sweep starts failing"
  assert_equal "$status" 0
  refute_called "curl"
}

@test "workflow: the 45-day quiet alert fires once, on the run that crosses the line" {
  export REPO=Melodymaifafa/gh-workflows PUSHOVER_TOKEN=t PUSHOVER_USER=u FAKE_NOW=2026-09-18T12:00:00Z
  runs="repos/$REPO/actions/workflows/pr-sweeper.yml/runs?status=completed&per_page=1"
  fake_route "repos/$REPO/commits?per_page=1" '[{"commit":{"committer":{"date":"2026-08-04T11:50:00Z"}}}]'
  # 45 天整是 09-18 11:50；上一轮 11:37 还没到 → 推。
  fake_route "$runs" '{"workflow_runs":[{"run_started_at":"2026-09-18T11:37:00Z"}]}'
  run run_block "$SWEEPER" "Alert when gh-workflows goes quiet"
  assert_equal "$status" 0
  assert_called "curl" 1

  # 上一轮 11:52 已经过线（那一轮推过了）→ 不再推。
  : >"$FAKE_LOG"
  fake_route "$runs" '{"workflow_runs":[{"run_started_at":"2026-09-18T11:52:00Z"}]}'
  run run_block "$SWEEPER" "Alert when gh-workflows goes quiet"
  refute_called "curl"

  # 最近有提交 → 不推。
  : >"$FAKE_LOG"
  fake_route "repos/$REPO/commits?per_page=1" '[{"commit":{"committer":{"date":"2026-09-10T00:00:00Z"}}}]'
  fake_route "$runs" '{"workflow_runs":[]}'
  run run_block "$SWEEPER" "Alert when gh-workflows goes quiet"
  assert_equal "$status" 0
  refute_called "curl"
}

@test "workflow: keepalive calls the enable endpoint and never fails the job" {
  export REPO=Melodymaifafa/gh-workflows
  run run_block "$SWEEPER" "Keep the schedule alive"
  assert_equal "$status" 0
  assert_called "gh api PUT repos/$REPO/actions/workflows/pr-sweeper.yml/enable" 1
  fake_route_fail -X PUT "repos/$REPO/actions/workflows/pr-sweeper.yml/enable" 1
  run run_block "$SWEEPER" "Keep the schedule alive"
  assert_equal "$status" 0
}

# quota_trail <M5 个数>：每次 M5 之后 10 分钟都撞了额度（不计数），最后一个 until 已过。
quota_trail() {
  local k m5s=() alerts=() at
  for ((k = 1; k <= $1; k++)); do
    at=$((700 - k * 100))
    m5s+=("$(m5_review "$((10 + k))" "$at")")
    alerts+=("$(alert_comment "$((20 + k))" fix-quota "$((NOW_EPOCH - 60))" "$((at - 10))")")
  done
  reviews "$(codex_findings 4863267293 "$H" 800)" "${m5s[@]}"
  comments "${alerts[@]}"
}

@test "retries that all hit quota still stop at 6 M5s with one retry-exhausted alert" {
  one_pr clean 70
  quota_trail 6
  sweep
  assert_contains "$output" "retries=0"
  refute_called "gh api POST repos/$R/pulls/7/reviews"
  assert_called "reason=retry-exhausted" 1
  assert_contains "$(fake_last_body "gh api POST")" "试了 6 次都卡在 Claude 额度上"
}

@test "five quota-ended retries still leave room for one more" {
  one_pr clean 70
  quota_trail 5
  sweep
  assert_called "gh api POST repos/$R/pulls/7/reviews" 1
  refute_called "reason=retry-exhausted"
}

@test "the private label is keyed, so hashing a guessed name does not match it" {
  one_pr clean 10
  sweep
  assert_contains "$output" "$LABEL"
  refute_contains "$output" "repo-$(printf '%s' "$R" | sha256sum | cut -c1-8)"
}

@test "without any key the private label carries no hash at all" {
  one_pr clean 10
  GH_TOKEN="" LABEL_KEY="" run bash "$REPO_ROOT/scripts/pr-sweep.sh"
  assert_contains "$output" "repo-private"
  refute_contains "$output" "private-caller"
}
