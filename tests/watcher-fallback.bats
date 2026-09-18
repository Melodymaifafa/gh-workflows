#!/usr/bin/env bats
# 合并 watcher（codex-approved-merge.yml 的 watch step）：Codex 审不了时换 Claude、
# 有问题的 head 绝不合并、路径 D（Claude clean）、CI / 可合并性告警只发一次。
# 跑的是 workflow 里的真 run 块，gh / curl / date / sleep 都是假的。

# bats 每个 @test 本来就跑在子 shell 里，export 只给本测试用；字面量 ${{ }} / ` / ~ 是要比对的文本；
# FAKE_LOG 由 setup_fake_env 导出。
# shellcheck disable=SC2016,SC2030,SC2031,SC2088,SC2153,SC2155

load test_helper/common

H=1a7e81f6b5f27f0a1dbc33c6fafda1bb86f1483d
OTHER=9b14fe3c0de5a1b2c3d4e5f60718293a4b5c6d7e
WF=.github/workflows/codex-approved-merge.yml
STEP='Wait for Codex and merge a clean exact head'
CODEX='chatgpt-codex-connector[bot]'
M2_QUOTA="🤖 Codex 这次审不了（额度用完/没回应），换 Claude 代审。

<!-- pr-guard: fallback head=$H reason=quota -->"

setup() {
  setup_fake_env
  export REPO=o/r PR_NUMBER=7 BASE_BRANCH=develop GH_TOKEN=actions-token
  export GITHUB_RUN_ID=111 GITHUB_WORKFLOW='Merge after clean Codex review'
  export ACTOR_TYPE=User HAS_PAT=true PUSHOVER_TOKEN=pt PUSHOVER_USER=pu
  export FAKE_NOW=2026-09-18T08:00:10Z TRIGGERED_AT=2026-09-18T08:00:00Z
  unset WATCH_SECONDS POLL_SECONDS SILENT_SECONDS
  fake_route repos/o/r/pulls/7 "$(pr_json)"
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" '[]'
  fake_route "repos/o/r/issues/7/comments?per_page=100" '[]'
}

# pr_json [head] [mergeable_state] [merged]
pr_json() {
  jq -n --arg h "${1:-$H}" --arg ms "${2:-clean}" --argjson merged "${3:-false}" '{
    state: "open", draft: false, title: "feat: x", merged: $merged,
    mergeable: true, mergeable_state: $ms,
    base: {ref: "develop"}, head: {sha: $h, repo: {full_name: "o/r"}}
  }'
}

# 路径 A：PR 打开事件，看 PR 正文上的 reaction。
path_a() {
  export EVENT_HEAD="$H" TARGET_ID=7
  fake_route "repos/o/r/issues/7/reactions?per_page=100" "${1:-[]}"
}

# 路径 B：主人令牌发的 M1 召唤评论。path_b [reactions] [m1_body 的第二个参数]
path_b() {
  export EVENT_HEAD='' TARGET_ID=500
  fake_route repos/o/r/issues/comments/500 \
    "$(gh_comment 500 Melodymaifafa OWNER "$(m1_body "$H" "${2:-1}")" 2026-09-18T08:00:00Z)"
  fake_route "repos/o/r/issues/comments/500/reactions?per_page=100" "${1:-[]}"
}

# 路径 D：<comment-json> [id]
path_d() {
  export EVENT_HEAD='' TARGET_ID="${2:-600}" TRIGGERED_AT=2026-09-18T08:00:00Z
  fake_route "repos/o/r/issues/comments/$TARGET_ID" "$1"
}

green_checks() {
  fake_cli pr_checks '[
    {"name":"lint-and-test","state":"SUCCESS","bucket":"pass","link":"https://github.com/o/r/actions/runs/222/job/1","workflow":"CI"},
    {"name":"iterate","state":"FAILURE","bucket":"fail","link":"https://github.com/o/r/actions/runs/333/job/1","workflow":"Claude iterates on Codex review"}
  ]'
}

thumbs_up() {
  json_array "$(gh_reaction +1 "$CODEX" 2026-09-18T08:01:00Z)"
}

# 本地加速：假 sleep 每次按 N 倍拨假时钟，长等待（CI 闸门、可合并性）几轮就到头。
# 共享 harness 没有这个开关，所以在本文件里包一层。
fast_sleep() {
  local dir="$BATS_TEST_TMPDIR/fastbin"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\nexec "%s/sleep" "$(( ${1%%%%[!0-9]*} * %s ))"\n' "$FAKE_BIN_DIR" "$1" >"$dir/sleep"
  chmod +x "$dir/sleep"
  export PATH="$dir:$PATH"
}

# M2 / M6 / Pushover 正文里绝不能出现触发词。
assert_bodies_inert() {
  local all
  all="$(fake_all_bodies)"
  refute_contains "$all" '@codex review'
  refute_contains "$all" 'claude-review-clean:'
}

refute_fallback() {
  if step_output fallback >/dev/null; then
    echo "unexpected fallback output: $(step_output fallback)" >&2
    return 1
  fi
  refute_called 'pr-guard: fallback'
}

# ---------- 默认值 ----------

@test "production timers default to the spec: poll 30 s, silent 300 s, timeout 1200 s" {
  block="$(extract_run_block "$REPO_ROOT/$WF" "$STEP")"
  assert_contains "$block" 'watch_seconds="${WATCH_SECONDS:-1200}"'
  assert_contains "$block" 'poll_seconds="${POLL_SECONDS:-30}"'
  assert_contains "$block" 'silent_seconds="${SILENT_SECONDS:-300}"'
  refute_contains "$block" 'Codex 复审超时无产出'
}

# ---------- 三种 fallback 触发 ----------

@test "quota: the real Codex quota comment falls back on the first poll" {
  path_a
  export TRIGGERED_AT=2026-09-17T08:02:54Z FAKE_NOW=2026-09-17T08:03:10Z
  fake_route "repos/o/r/issues/7/comments?per_page=100" \
    "$(json_array "$(cat "$FIXTURES_DIR/codex/quota-comment.json")")"

  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_equal "$(step_output fallback)" true
  assert_equal "$(step_output head)" "$H"
  assert_equal "$(step_output reason)" quota
  assert_called 'gh api POST repos/o/r/issues/7/comments' 1
  assert_equal "$(fake_last_body 'gh api POST repos/o/r/issues/7/comments')" "$M2_QUOTA"
  assert_called '[token=actions-token]'
  refute_called 'sleep'
  refute_called 'gh pr merge'
  assert_bodies_inert
}

@test "quota with a bot actor posts nothing and hands nothing to Claude" {
  path_a
  export ACTOR_TYPE=Bot TRIGGERED_AT=2026-09-17T08:02:54Z FAKE_NOW=2026-09-17T08:03:10Z
  fake_route "repos/o/r/issues/7/comments?per_page=100" \
    "$(json_array "$(cat "$FIXTURES_DIR/codex/quota-comment.json")")"

  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_fallback
  refute_called 'gh api POST'
  assert_contains "$output" 'the sweeper re-requests review'
}

@test "a quota comment from before this request does not trigger a fallback" {
  path_b "$(json_array "$(gh_reaction eyes "$CODEX" 2026-09-18T08:00:20Z)")"
  export WATCH_SECONDS=90
  old_quota="$(json_array "$(gh_comment 1 "$CODEX" NONE 'You have reached your Codex usage limits for code reviews.' 2026-09-18T07:00:00Z)")"
  for n in 1 2 3; do fake_route "repos/o/r/issues/7/comments?per_page=100" "$old_quota" "$n"; done
  # 超时时 Codex 已给出针对 H 的 clean 评论：路径 C 接手，本 run 也不换 Claude。
  fake_route "repos/o/r/issues/7/comments?per_page=100" \
    "$(json_array \
      "$(gh_comment 1 "$CODEX" NONE 'You have reached your Codex usage limits for code reviews.' 2026-09-18T07:00:00Z)" \
      "$(gh_comment 2 "$CODEX" NONE "Codex Review: Didn't find any major issues. 🎉

**Reviewed commit:** \`${H:0:10}\`" 2026-09-18T08:01:00Z)")" 4

  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_fallback
  assert_contains "$output" 'no clean sign-off before timeout'
}

@test "silent (path B): 300 s with no eyes, comment or review falls back" {
  path_b
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_equal "$(step_output fallback)" true
  assert_equal "$(step_output reason)" silent
  assert_called 'sleep 30' 10
  assert_equal "$(fake_last_body 'gh api POST repos/o/r/issues/7/comments')" \
    "🤖 Codex 这次审不了（额度用完/没回应），换 Claude 代审。

<!-- pr-guard: fallback head=$H reason=silent -->"
  assert_bodies_inert
}

@test "silent never fires on path A; the timeout does and replaces the old alert" {
  path_a
  export WATCH_SECONDS=330
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_equal "$(step_output fallback)" true
  assert_equal "$(step_output reason)" timeout
  assert_called 'sleep 30' 11
  assert_called 'reason=timeout' 1
  refute_called 'reason=silent'
  # 旧的「Codex 复审超时无产出」Pushover 没了。
  refute_called 'curl'
  assert_bodies_inert
}

@test "path B with a Codex eyes reaction is not silent and waits for the timeout" {
  path_b "$(json_array "$(gh_reaction eyes "$CODEX" 2026-09-18T08:00:20Z)")"
  export SILENT_SECONDS=60 WATCH_SECONDS=150
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_equal "$(step_output reason)" timeout
  assert_called 'sleep 30' 5
}

@test "missing CODEX_TRIGGER_TOKEN: one auth alert with GITHUB_TOKEN, no M2, no Claude review" {
  path_a
  export HAS_PAT=false TRIGGERED_AT=2026-09-17T08:02:54Z FAKE_NOW=2026-09-17T08:03:10Z
  fake_route "repos/o/r/issues/7/comments?per_page=100" \
    "$(json_array "$(cat "$FIXTURES_DIR/codex/quota-comment.json")")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_equal "$(step_output fallback)" false
  refute_called 'pr-guard: fallback'
  assert_called curl 1
  assert_called 'gh api POST repos/o/r/issues/7/comments' 1
  assert_called '[token=actions-token]'
  assert_equal "$(fake_last_body 'gh api POST repos/o/r/issues/7/comments')" \
    "🤖 这个仓库缺 CODEX_TRIGGER_TOKEN 密钥，Claude 代审没法发结果。重跑 onboard.sh 刷密钥后会自动继续。

<!-- pr-guard: alert head=$H reason=auth until=- -->"
  assert_bodies_inert
}

@test "missing CODEX_TRIGGER_TOKEN with an (H, auth) marker already: no Pushover, no post" {
  path_b
  export HAS_PAT=false
  fake_route "repos/o/r/issues/7/comments?per_page=100" \
    "$(json_array "$(gh_comment 1 'github-actions[bot]' NONE "缺密钥。

$(m6_marker "$H" auth)")")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_equal "$(step_output fallback)" false
  refute_called curl
  refute_called 'gh api POST'
}

@test "timeout on a PR that already merged does not fall back" {
  path_a
  export WATCH_SECONDS=60
  fake_route repos/o/r/pulls/7 "$(pr_json "$H" clean true)"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_fallback
}

@test "a head that moved before the fallback posts nothing" {
  path_a
  export TRIGGERED_AT=2026-09-17T08:02:54Z FAKE_NOW=2026-09-17T08:03:10Z
  fake_route "repos/o/r/issues/7/comments?per_page=100" \
    "$(json_array "$(cat "$FIXTURES_DIR/codex/quota-comment.json")")"
  # 第 1 次读 PR：开始；第 2 次：轮询时还是 H；第 3 次：fallback 前已换 head。
  fake_route repos/o/r/pulls/7 "$(pr_json)" 1
  fake_route repos/o/r/pulls/7 "$(pr_json)" 2
  fake_route repos/o/r/pulls/7 "$(pr_json "$OTHER")" 3
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_fallback
}

# ---------- 有问题的 head 绝不合并 ----------

@test "path A: an old Codex review on H (before this request) blocks the merge" {
  path_a "$(thumbs_up)"
  green_checks
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" \
    "$(json_array "$(gh_review 9 "$CODEX" NONE "$H" 'findings' 2026-09-01T00:00:00Z)")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_contains "$output" 'has review findings'
  refute_called 'gh pr merge'
  refute_fallback
}

@test "path B accepts an M1 that also carries a fix-round marker" {
  path_b "$(thumbs_up)" 3
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_called "gh pr merge 7 --repo o/r --squash --delete-branch --match-head-commit $H" 1
}

@test "path B accepts a sweeper kick M1" {
  path_b "$(thumbs_up)" kick
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_called "gh pr merge 7 --repo o/r --squash --delete-branch --match-head-commit $H" 1
}

@test "path B: a sweeper kick M1 still falls back when Codex stays silent" {
  path_b '[]' kick
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_equal "$(step_output reason)" silent
}

@test "path B: an OWNER M3 on H blocks the merge" {
  path_b "$(thumbs_up)"
  green_checks
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" \
    "$(json_array "$(gh_review 9 Melodymaifafa OWNER "$H" "$(m3_body "$H")")")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_called 'gh pr merge'
}

@test "path B: a forged claude[bot] M3 is ignored and the Codex 👍 merges" {
  path_b "$(thumbs_up)"
  green_checks
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" \
    "$(json_array "$(cat "$FIXTURES_DIR/forged/claude-bot-findings-review.json")")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_called "gh pr merge 7 --repo o/r --squash --delete-branch --match-head-commit $H" 1
}

@test "path C: a Codex clean comment still refuses a head with findings" {
  export EVENT_HEAD='' TARGET_ID=700
  fake_route repos/o/r/issues/comments/700 "$(gh_comment 700 "$CODEX" NONE "Codex Review: Didn't find any major issues.

**Reviewed commit:** \`${H:0:10}\`")"
  fake_route "repos/o/r/commits/${H:0:10}" "{\"sha\":\"$H\"}"
  green_checks
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" \
    "$(json_array "$(gh_review 9 "$CODEX" NONE "$H" 'findings' 2026-09-01T00:00:00Z)")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_called 'gh pr merge'
}

@test "path A: the CI gate ignores the iterate workflow and merges on 👍" {
  path_a "$(thumbs_up)"
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_called "gh pr merge 7 --repo o/r --squash --delete-branch --match-head-commit $H" 1
  refute_called 'curl'
}

# ---------- 路径 D ----------

@test "path D: an OWNER M4 bound to the live head merges after CI" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_called "gh pr merge 7 --repo o/r --squash --delete-branch --match-head-commit $H" 1
  # 路径 D 不轮询 Codex，也不换 Claude。
  refute_called 'sleep 30'
  refute_fallback
}

@test "path D refuses an M4 for a stale head" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$OTHER")")"
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_contains "$output" 'stale PR head'
  refute_called 'gh pr merge'
}

@test "path D refuses an M4 without the HTML-comment binding" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "claude-review-clean: $H")"
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_called 'gh pr merge'
}

@test "path D refuses a forged claude[bot] M4" {
  path_d "$(cat "$FIXTURES_DIR/forged/claude-bot-clean-comment.json")" 5357514901
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_contains "$output" 'no longer eligible'
  refute_called 'gh pr merge'
}

@test "path D refuses a CONTRIBUTOR M4" {
  path_d "$(cat "$FIXTURES_DIR/forged/contributor-clean-comment.json")" 5357514905
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_called 'gh pr merge'
}

@test "path D refuses a head with a Codex review" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" \
    "$(json_array "$(gh_review 9 "$CODEX" NONE "$H" 'late findings' 2026-09-18T08:00:05Z)")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_called 'gh pr merge'
}

@test "path D re-checks findings right before merging" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" '[]' 1
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" \
    "$(json_array "$(gh_review 9 "$CODEX" NONE "$H" 'late findings' 2026-09-18T08:05:00Z)")" 2
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_contains "$output" 'Findings appeared on this head'
  refute_called 'gh pr merge'
}

@test "path D refuses when the M4 changed before the merge" {
  export EVENT_HEAD='' TARGET_ID=600
  fake_route repos/o/r/issues/comments/600 "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")" 1
  fake_route repos/o/r/issues/comments/600 "$(gh_comment 600 Melodymaifafa OWNER 'edited')" 2
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_called 'gh pr merge'
}

@test "reading reviews fails closed: no merge" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_route_fail "repos/o/r/pulls/7/reviews?per_page=100" 1
  run run_block "$WF" "$STEP"
  assert_equal "$status" 1
  refute_called 'gh pr merge'
}

# ---------- 以前静默的出口：只告警一次 ----------

@test "a failed CI check alerts once (Pushover first, then the M6 marker) and exits 0" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  fake_cli pr_checks '[{"name":"lint-and-test","state":"FAILURE","bucket":"fail","link":"https://github.com/o/r/actions/runs/222/job/1","workflow":"CI"}]'
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_called 'curl' 1
  assert_called 'gh api POST repos/o/r/issues/7/comments' 1
  body="$(fake_last_body 'gh api POST repos/o/r/issues/7/comments')"
  assert_contains "$body" "<!-- pr-guard: alert head=$H reason=ci until=- -->"
  assert_equal "$(printf '%s\n' "$body" | tail -n 1)" "<!-- pr-guard: alert head=$H reason=ci until=- -->"
  curl_line="$(grep -nF 'curl' "$FAKE_LOG" | cut -d: -f1)"
  post_line="$(grep -nF 'gh api POST' "$FAKE_LOG" | cut -d: -f1)"
  [ "$curl_line" -lt "$post_line" ]
  refute_called 'gh pr merge'
  assert_bodies_inert
}

@test "the ci alert is not repeated when a trusted marker for (H, ci) exists" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  fake_cli pr_checks '[{"name":"lint-and-test","state":"FAILURE","bucket":"fail","link":"x","workflow":"CI"}]'
  fake_route "repos/o/r/issues/7/comments?per_page=100" \
    "$(json_array "$(gh_comment 1 'github-actions[bot]' NONE "CI 没过。

$(m6_marker "$H" ci)")")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_called 'curl'
  refute_called 'gh api POST'
}

@test "a claude[bot] marker does not suppress the alert; one for another reason does not either" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  fake_cli pr_checks '[{"name":"lint-and-test","state":"FAILURE","bucket":"fail","link":"x","workflow":"CI"}]'
  fake_route "repos/o/r/issues/7/comments?per_page=100" "$(json_array \
    "$(gh_comment 1 'claude[bot]' NONE "$(m6_marker "$H" ci)")" \
    "$(gh_comment 2 'github-actions[bot]' NONE "$(m6_marker "$H" unmergeable)")")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_called 'curl' 1
  assert_called "reason=ci until=-" 1
}

@test "checks that never settle alert ci once" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  fake_cli pr_checks '[{"name":"lint-and-test","state":"PENDING","bucket":"pending","link":"x","workflow":"CI"}]'
  fast_sleep 60
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_contains "$output" 'did not settle'
  assert_called 'curl' 1
  assert_called 'gh api POST repos/o/r/issues/7/comments' 1
  assert_called "reason=ci until=-" 1
  refute_called 'gh pr merge'
}

@test "a PR that never becomes mergeable alerts unmergeable once" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_route repos/o/r/pulls/7 "$(pr_json "$H" blocked)"
  fast_sleep 20
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_called 'curl' 1
  assert_called "reason=unmergeable until=-" 1
  refute_called 'gh pr merge'
  assert_bodies_inert
}

@test "no Pushover without both Pushover secrets; the marker is still posted" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  fake_cli pr_checks '[{"name":"lint-and-test","state":"FAILURE","bucket":"fail","link":"x","workflow":"CI"}]'
  export PUSHOVER_USER=''
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_called 'curl'
  assert_called "reason=ci until=-" 1
}
