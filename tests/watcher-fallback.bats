#!/usr/bin/env bats
# 合并 watcher（codex-approved-merge.yml 的 watch step）：不在 runner 上等 Codex（路径 F 只看一眼）、
# Codex 审不了时换 Claude（路径 G）、有问题的 head 绝不合并、路径 D（Claude clean）、
# CI / 可合并性告警只发一次。
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
  export FAKE_NOW=2026-09-18T08:06:00Z
  fake_route repos/o/r/pulls/7 "$(pr_json)"
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" '[]'
  fake_route "repos/o/r/issues/7/comments?per_page=100" '[]'
  no_running_fix o/r
}

# pr_json [head] [mergeable_state] [merged]
pr_json() {
  jq -n --arg h "${1:-$H}" --arg ms "${2:-clean}" --argjson merged "${3:-false}" '{
    state: "open", draft: false, title: "feat: x", merged: $merged,
    mergeable: true, mergeable_state: $ms,
    base: {ref: "develop"}, head: {sha: $h, ref: "topic", repo: {full_name: "o/r"}}
  }'
}

# 路径 G：巡检看到 Codex 没接召唤后留的标记。path_g <reason> [head] [作者] [身份]
path_g() {
  export TARGET_ID=800
  fake_route repos/o/r/issues/comments/800 "$(gh_comment 800 "${3:-Melodymaifafa}" "${4:-OWNER}" \
    "🤖 巡检：Codex 没接这次审查。"$'\n\n'"<!-- pr-guard: codex-silent head=${2:-$H} reason=$1 -->")"
}

# 路径 D：<comment-json> [id]
path_d() {
  export TARGET_ID="${2:-600}"
  fake_route "repos/o/r/issues/comments/$TARGET_ID" "$1"
}

green_checks() {
  fake_cli pr_checks '[
    {"name":"lint-and-test","state":"SUCCESS","bucket":"pass","link":"https://github.com/o/r/actions/runs/222/job/1","workflow":"CI"},
    {"name":"iterate","state":"FAILURE","bucket":"fail","link":"https://github.com/o/r/actions/runs/333/job/1","workflow":"Claude iterates on Codex review"}
  ]'
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

# ---------- 不在 runner 上等 Codex ----------

@test "the job never starts on a PR event or a review request: nothing waits for Codex" {
  local job_if
  job_if="$(awk '/^  watch-and-merge:/{f=1} f&&/^    concurrency:/{exit} f&&!/^ *#/' "$REPO_ROOT/$WF")"
  refute_contains "$job_if" "pull_request_target"
  refute_contains "$job_if" "'@codex review'"
  assert_contains "$job_if" "pr-guard: codex-thumbs head="
  assert_contains "$job_if" "pr-guard: codex-summary head="
  assert_contains "$job_if" "pr-guard: codex-silent head="
  block="$(extract_run_block "$REPO_ROOT/$WF" "$STEP")"
  refute_contains "$block" 'WATCH_SECONDS'
  refute_contains "$block" 'POLL_SECONDS'
  refute_contains "$block" 'SILENT_SECONDS'
}

# ---------- 路径 F：巡检看到 👍 ----------

@test "path F: a Codex 👍 on the PR body after the named summon merges after CI" {
  path_f o/r "$H"
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_called "gh pr merge 7 --repo o/r --squash --delete-branch --match-head-commit $H" 1
  refute_called 'curl'
}

@test "path F: a 👍 on the summon comment counts too" {
  path_f o/r "$H"
  fake_route "repos/o/r/issues/7/reactions?per_page=100" '[]'
  fake_route "repos/o/r/issues/comments/500/reactions?per_page=100" \
    "$(json_array "$(gh_reaction +1 "$CODEX" 2026-09-18T08:01:00Z)")"
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_called "gh pr merge 7 --repo o/r --squash --delete-branch --match-head-commit $H" 1
}

@test "path F: no 👍 yet exits at once — no sleep, no fallback, no merge" {
  path_f o/r "$H"
  fake_route "repos/o/r/issues/7/reactions?per_page=100" '[]'
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_contains "$output" 'No Codex 👍 after the named review request'
  refute_called 'sleep'
  refute_fallback
  refute_called 'gh pr merge'
}

@test "path F: a 👍 from before the named summon is not a sign-off" {
  path_f o/r "$H" 2026-09-18T07:59:00Z
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_called 'gh pr merge'
}

@test "path F accepts a named summon that also carries a fix-round marker, or is a sweeper kick" {
  for kind in 3 kick; do
    : >"$FAKE_LOG"
    path_f o/r "$H" 2026-09-18T08:01:00Z "$(m1_body "$H" "$kind")"
    green_checks
    run run_block "$WF" "$STEP"
    assert_equal "$status" 0
    assert_called "gh pr merge 7 --repo o/r --squash --delete-branch --match-head-commit $H" 1
  done
}

@test "path F refuses a marker for a stale head, or without the summon binding" {
  path_f o/r "$OTHER"
  run run_block "$WF" "$STEP"
  assert_contains "$output" 'targets a stale PR head'
  refute_called 'gh pr merge'
  fake_route repos/o/r/issues/comments/900 "$(gh_comment 900 Melodymaifafa OWNER "<!-- pr-guard: codex-thumbs head=$H -->")"
  run run_block "$WF" "$STEP"
  assert_contains "$output" 'has no exact HEAD binding'
  refute_called 'gh pr merge'
}

@test "path F refuses a named summon bound to another head, or written by claude[bot]" {
  path_f o/r "$H" 2026-09-18T08:01:00Z "$(m1_body "$OTHER" 1)"
  run run_block "$WF" "$STEP"
  assert_contains "$output" 'not a trusted one for this head'
  refute_called 'gh pr merge'
  fake_route repos/o/r/issues/comments/500 "$(gh_comment 500 'claude[bot]' NONE "$(m1_body "$H" 1)" 2026-09-18T08:00:00Z)"
  run run_block "$WF" "$STEP"
  assert_contains "$output" 'not a trusted one for this head'
  refute_called 'gh pr merge'
}

@test "path F refuses a marker that is not written by the owner" {
  path_f o/r "$H"
  fake_route repos/o/r/issues/comments/900 "$(gh_comment 900 'claude[bot]' NONE "<!-- pr-guard: codex-thumbs head=$H summon=500 -->")"
  run run_block "$WF" "$STEP"
  assert_contains "$output" 'no longer eligible'
  refute_called 'gh pr merge'
}

@test "path F: an old Codex review on H blocks the merge" {
  path_f o/r "$H"
  green_checks
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" \
    "$(json_array "$(gh_review 9 "$CODEX" NONE "$H" 'findings' 2026-09-01T00:00:00Z)")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_contains "$output" 'has review findings'
  refute_called 'gh pr merge'
  refute_fallback
}

@test "path F: an OWNER M3 on H blocks the merge; a forged claude[bot] M3 does not" {
  path_f o/r "$H"
  green_checks
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" \
    "$(json_array "$(gh_review 9 Melodymaifafa OWNER "$H" "$(m3_body "$H")")")"
  run run_block "$WF" "$STEP"
  refute_called 'gh pr merge'
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" \
    "$(json_array "$(cat "$FIXTURES_DIR/forged/claude-bot-findings-review.json")")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_called "gh pr merge 7 --repo o/r --squash --delete-branch --match-head-commit $H" 1
}

# ---------- 路径 H：巡检看到 Codex 的审查摘要审完了、没意见 ----------

# summary_json <fixture> [审的 commit] [改的时间] [作者] [身份]：Codex 的审查摘要（真数据，评论 6230570700），
# 发在 o/r#7 上。默认 08:01 审完：FAKE_NOW 是 08:06，满 2 分钟。
summary_json() {
  jq --arg sha "${2:-$H}" --arg h "$H" --arg at "${3:-2026-09-18T08:01:00Z}" \
    --arg login "${4:-$CODEX}" --arg assoc "${5:-NONE}" '
      .body |= gsub($h; $sha) | .updated_at = $at | .author_association = $assoc
      | .issue_url = "https://api.github.com/repos/o/r/issues/7"
      | .user.login = $login | .user.type = (if ($login | endswith("[bot]")) then "Bot" else "User" end)' \
    "$FIXTURES_DIR/codex/$1.json"
}

# path_h [标记绑的 head] [标记作者] [身份]：巡检留的 codex-summary 标记（评论 950），点名那条摘要；
# 摘要默认审完了 H、没意见。
path_h() {
  export TARGET_ID=950
  fake_route repos/o/r/issues/comments/950 "$(gh_comment 950 "${2:-Melodymaifafa}" "${3:-OWNER}" \
    "🤖 巡检：Codex 审过没意见（审查摘要显示审完了），请合并检查跑一次。"$'\n\n'"<!-- pr-guard: codex-summary head=${1:-$H} comment=6230570700 -->" \
    2026-09-18T08:05:00Z)"
  fake_route repos/o/r/issues/comments/6230570700 "$(summary_json summary-completed)"
}

@test "path H: a Codex summary Completed on H with no findings merges after CI" {
  path_h
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_called "gh pr merge 7 --repo o/r --squash --delete-branch --match-head-commit $H" 1
  refute_fallback
  refute_called 'curl'
}

@test "path H: a summary Running on H, Completed on another commit, or under 2 minutes old does not merge" {
  for summary in "summary-running" "summary-completed $OTHER" "summary-completed $H 2026-09-18T08:05:00Z"; do
    : >"$FAKE_LOG"
    path_h
    # shellcheck disable=SC2086  # 故意拆成 fixture、commit、时间几个参数
    fake_route repos/o/r/issues/comments/6230570700 "$(summary_json $summary)"
    green_checks
    run run_block "$WF" "$STEP"
    assert_equal "$status" 0
    assert_contains "$output" 'does not show a clean review of this head'
    refute_called 'sleep'
    refute_called 'gh pr merge'
    refute_fallback
  done
}

@test "path H: a forged summary from the OWNER, github-actions, or another PR does not merge" {
  for who in "Melodymaifafa OWNER" "github-actions[bot] NONE"; do
    : >"$FAKE_LOG"
    path_h
    # shellcheck disable=SC2086  # 故意拆成 login 和身份两个参数
    fake_route repos/o/r/issues/comments/6230570700 "$(summary_json summary-completed "$H" 2026-09-18T08:01:00Z $who)"
    run run_block "$WF" "$STEP"
    assert_contains "$output" 'does not show a clean review of this head'
    refute_called 'gh pr merge'
  done
  fake_route repos/o/r/issues/comments/6230570700 \
    "$(summary_json summary-completed | jq '.issue_url = "https://api.github.com/repos/o/r/issues/17"')"
  run run_block "$WF" "$STEP"
  assert_contains "$output" 'does not show a clean review of this head'
  refute_called 'gh pr merge'
}

@test "path H refuses a marker for a stale head, or one not written by the owner" {
  path_h "$OTHER"
  run run_block "$WF" "$STEP"
  assert_contains "$output" 'Codex summary marker targets a stale PR head'
  refute_called 'gh pr merge'
  path_h "$H" 'claude[bot]' NONE
  run run_block "$WF" "$STEP"
  assert_contains "$output" 'no longer eligible'
  refute_called 'gh pr merge'
}

@test "path H: a Codex review on H blocks the merge even though the summary says Completed" {
  path_h
  green_checks
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" \
    "$(json_array "$(gh_review 9 "$CODEX" NONE "$H" 'findings' 2026-09-18T08:02:00Z)")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_contains "$output" 'has review findings'
  refute_called 'gh pr merge'
}

@test "path H re-checks the summary after CI: a re-review that started meanwhile does not merge" {
  path_h
  fake_route repos/o/r/issues/comments/6230570700 "$(summary_json summary-completed)" 1
  fake_route repos/o/r/issues/comments/6230570700 "$(summary_json summary-running "$H" 2026-09-18T08:07:00Z)" 2
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_contains "$output" 'Codex review summary changed; skipping'
  refute_called 'gh pr merge'
}

# ---------- 路径 G：Codex 没接，换 Claude ----------

@test "path G: an owner codex-silent marker for the live head falls back with its reason" {
  for reason in quota silent timeout; do
    : >"$FAKE_LOG"; : >"$GITHUB_OUTPUT"
    path_g "$reason"
    run run_block "$WF" "$STEP"
    assert_equal "$status" 0
    assert_equal "$(step_output fallback)" true
    assert_equal "$(step_output head)" "$H"
    assert_equal "$(step_output reason)" "$reason"
    # 叫醒这一步的 codex-silent 评论已经说了「换 Claude」，这里不再发第二条（M2）。
    refute_called 'gh api POST'
    assert_contains "$output" "Codex unavailable ($reason); Claude reviews $H"
    refute_called 'sleep'
    refute_called 'gh pr merge'
    assert_bodies_inert
  done
}

@test "path G with a bot actor posts nothing and hands nothing to Claude" {
  path_g silent
  export ACTOR_TYPE=Bot
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_fallback
  refute_called 'gh api POST'
  assert_contains "$output" 'the sweeper re-requests review'
}

@test "path G refuses a stale head, an unknown reason, and a marker not written by the owner" {
  path_g silent "$OTHER"
  run run_block "$WF" "$STEP"
  assert_contains "$output" 'targets a stale PR head'
  refute_fallback
  path_g sleepy
  run run_block "$WF" "$STEP"
  assert_contains "$output" 'has no exact HEAD binding'
  refute_fallback
  path_g silent "$H" 'claude[bot]' NONE
  run run_block "$WF" "$STEP"
  refute_fallback
}

@test "path G: a head with findings is iterate's, not Claude's review" {
  path_g silent
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" \
    "$(json_array "$(gh_review 9 "$CODEX" NONE "$H" 'findings')")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_fallback
}

@test "path G on a merged PR does not fall back" {
  path_g timeout
  fake_route repos/o/r/pulls/7 "$(pr_json "$H" clean true | jq '.state = "closed"')"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_fallback
}

@test "a head that moved before the fallback posts nothing" {
  path_g quota
  # 第 1 次读 PR：开始时还是 H；第 2 次：fallback 前已换 head。
  fake_route repos/o/r/pulls/7 "$(pr_json)" 1
  fake_route repos/o/r/pulls/7 "$(pr_json "$OTHER")" 2
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_fallback
}

@test "missing CODEX_TRIGGER_TOKEN: one pat-missing alert with GITHUB_TOKEN, no M2, no Claude review" {
  path_g quota
  export HAS_PAT=false
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_equal "$(step_output fallback)" false
  refute_called 'pr-guard: fallback'
  assert_called curl 1
  assert_called 'gh api POST repos/o/r/issues/7/comments' 1
  assert_called '[token=actions-token]'
  assert_equal "$(fake_last_body 'gh api POST repos/o/r/issues/7/comments')" \
    "🤖 这个仓库缺 CODEX_TRIGGER_TOKEN 密钥，Claude 代审没法发结果。重跑 onboard.sh 刷密钥后会自动继续。

<!-- pr-guard: alert head=$H reason=pat-missing until=- -->"
  assert_bodies_inert
}

@test "missing CODEX_TRIGGER_TOKEN with an (H, pat-missing) marker already: no Pushover, no post" {
  path_g silent
  export HAS_PAT=false
  fake_route "repos/o/r/issues/7/comments?per_page=100" \
    "$(json_array "$(gh_comment 1 'github-actions[bot]' NONE "缺密钥。

$(m6_marker "$H" pat-missing)")")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_equal "$(step_output fallback)" false
  refute_called curl
  refute_called 'gh api POST'
}

# ---------- 路径 C ----------

@test "path C: a Codex clean comment still refuses a head with findings" {
  export TARGET_ID=700
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
  export TARGET_ID=600
  fake_route repos/o/r/issues/comments/600 "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")" 1
  fake_route repos/o/r/issues/comments/600 "$(gh_comment 600 Melodymaifafa OWNER 'edited')" 2
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_called 'gh pr merge'
}

# ---------- 路径 E：修满轮数后 Claude 逐条核过 Codex 剩下的意见（M8） ----------

# m8_body <head> <review-ids>
m8_body() {
  printf '🤖 自动修满轮数，Codex 剩下的意见 Claude 核过都不拦合并。\n\n<!-- claude-judge-clean: head=%s reviews=%s -->' "$1" "$2"
}

codex_findings_on_h() { # codex_findings_on_h <id> ...
  local id reviews=()
  for id in "$@"; do reviews+=("$(gh_review "$id" "$CODEX" NONE "$H" 'P2 nit')"); done
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" "$(json_array "${reviews[@]}")"
}

@test "path E: an OWNER M8 merges past exactly the Codex reviews it judged" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m8_body "$H" 901,902)")"
  codex_findings_on_h 901 902
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_called "gh pr merge 7 --repo o/r --squash --delete-branch --match-head-commit $H" 1
  refute_called 'sleep 30'
  refute_fallback
}

@test "path E: a Codex review on H the judge never saw still blocks the merge" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m8_body "$H" 901)")"
  codex_findings_on_h 901 902
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_contains "$output" 'has review findings'
  refute_called 'gh pr merge'
}

@test "path E: findings that land after the M8 still block the merge" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m8_body "$H" 901)")"
  green_checks
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" \
    "$(json_array "$(gh_review 901 "$CODEX" NONE "$H" 'P2 nit')")" 1
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" \
    "$(json_array "$(gh_review 901 "$CODEX" NONE "$H" 'P2 nit')" "$(gh_review 903 "$CODEX" NONE "$H" 'new')")" 2
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_contains "$output" 'Findings appeared on this head'
  refute_called 'gh pr merge'
}

@test "path E refuses an M8 for a stale head" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m8_body "$OTHER" 901)")"
  codex_findings_on_h 901
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_contains "$output" 'stale PR head'
  refute_called 'gh pr merge'
}

@test "path E refuses an M8 that is not written by the owner" {
  path_d "$(gh_comment 600 'claude[bot]' NONE "$(m8_body "$H" 901)")"
  codex_findings_on_h 901
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_contains "$output" 'no longer eligible'
  refute_called 'gh pr merge'
}

@test "path E refuses when the M8 changed before the merge" {
  export TARGET_ID=600
  fake_route repos/o/r/issues/comments/600 "$(gh_comment 600 Melodymaifafa OWNER "$(m8_body "$H" 901)")" 1
  fake_route repos/o/r/issues/comments/600 "$(gh_comment 600 Melodymaifafa OWNER "$(m8_body "$H" 901,902)")" 2
  codex_findings_on_h 901
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_contains "$output" 'Claude judge comment changed'
  refute_called 'gh pr merge'
}

@test "a Codex review with findings still blocks path D: only an M8 can name it" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  codex_findings_on_h 901
  green_checks
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_called 'gh pr merge'
}

# ---------- 以前没推上去的意见（carried-findings）：没人处理之前不合 ----------
#
# wechat-mimic-finetune PR #15：修复没推上去，下一次复审只看新 head、没再报那条 P1，
# PR 带着 bug 自动合了进去。iterate 现在留一个 carried-findings 标记，合并前必须是关着的。

carried_comment() { # carried_comment <id> <login> <assoc> <review> [cleared]
  local m="carried-findings review=$4 from=$OTHER"
  [ -z "${5:-}" ] || m="carried-findings-cleared review=$4 head=$H"
  gh_comment "$1" "$2" "$3" "改好了，但推不上去。

<!-- pr-guard: $m -->"
}

@test "carried: an open carried finding blocks a clean, green head and alerts once" {
  unset CODEX_TRIGGER_TOKEN
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_route "repos/o/r/issues/7/comments?per_page=100" "$(json_array \
    "$(carried_comment 1 'github-actions[bot]' NONE 3001)")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_contains "$output" 'Unfinished findings from review(s) 3001 are still open'
  refute_called 'gh pr merge'
  # 没有主人的 PAT，补不了请修复的那条 review：照旧告警停下
  refute_called 'gh api POST repos/o/r/pulls/7/reviews'
  assert_called 'curl' 1
  body="$(fake_last_body 'gh api POST repos/o/r/issues/7/comments')"
  assert_contains "$body" '更早的 review 3001 里的意见还没修完'
  assert_contains "$body" '仓库没配 CODEX_TRIGGER_TOKEN'
  assert_contains "$body" "<!-- pr-guard: alert head=$H reason=carried-open until=- -->"
  assert_bodies_inert
}

# Codex 2026-10-08 的 P2：新 head 审查通过了，就没有「下一轮修复」来带上开着的旧意见 ——
# iterate 只在 head 上有意见时开修，巡检又把 carried-open 当停车，PR 一直卡着等人。
# 所以有主人的 PAT 时，在这个 head 上补一条有意见的 review（M3 形状），iterate 照常开一轮。
reraise_review() { # reraise_review <id> <reviews>：合并检查补过的那条，点了这几条的名
  gh_review "$1" Melodymaifafa OWNER "$H" "🤖 补一条请修复。

<!-- claude-review-findings: $H -->
<!-- pr-guard: carried-reraise head=$H reviews=$2 -->"
}

@test "carried: with the owner PAT, a clean head held only by old findings asks iterate for a fix round" {
  export CODEX_TRIGGER_TOKEN=owner-pat
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_route "repos/o/r/issues/7/comments?per_page=100" "$(json_array \
    "$(carried_comment 1 'github-actions[bot]' NONE 3001)")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_called 'gh pr merge'
  # 不停车、不推手机：iterate 会开一轮把它们带上
  refute_called 'curl'
  refute_called 'reason=carried-open'
  assert_called 'gh api POST repos/o/r/pulls/7/reviews' 1
  call="$(fake_calls 'gh api POST repos/o/r/pulls/7/reviews')"
  assert_contains "$call" '[token=owner-pat]'
  assert_contains "$call" 'event=COMMENT'
  assert_contains "$call" "commit_id=$H"
  body="$(fake_last_body 'gh api POST repos/o/r/pulls/7/reviews')"
  assert_contains "$body" '更早的 review 3001 里还有没修完的意见'
  assert_contains "$body" "<!-- claude-review-findings: $H -->"
  assert_contains "$body" "<!-- pr-guard: carried-reraise head=$H reviews=3001 -->"
  assert_bodies_inert
}

# 同一批意见在每个 head 上只补一次：补过的那一轮判完（M8 点了它的名）旧意见还开着，再补只会原地转圈。
@test "carried: a head that already asked for a fix round parks with the alert instead of asking again" {
  export CODEX_TRIGGER_TOKEN=owner-pat
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m8_body "$H" 950)")"
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" "$(json_array "$(reraise_review 950 3001)")"
  green_checks
  fake_route "repos/o/r/issues/7/comments?per_page=100" "$(json_array \
    "$(carried_comment 1 'github-actions[bot]' NONE 3001)")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_called 'gh pr merge'
  refute_called 'gh api POST repos/o/r/pulls/7/reviews'
  assert_called 'curl' 1
  body="$(fake_last_body 'gh api POST repos/o/r/issues/7/comments')"
  assert_contains "$body" '已经请自动修复带上它们修过一轮，还是没关掉'
  assert_contains "$body" "<!-- pr-guard: alert head=$H reason=carried-open until=- -->"
}

# Codex 2026-10-08 的 P2：补过的那一轮开修之后才记上账的意见（3002）不在它带上的那批里，
# judge 也只放行了那一批。只按 head 算「补过」，3002 就跟着停车、再没人修 —— 它得再补一条。
@test "carried: a finding recorded after this head's fix round started gets its own fix round" {
  export CODEX_TRIGGER_TOKEN=owner-pat
  m8="$(gh_comment 600 Melodymaifafa OWNER "$(m8_body "$H" 950,3001)")"
  path_d "$m8"
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" "$(json_array "$(reraise_review 950 3001)")"
  green_checks
  fake_route "repos/o/r/issues/7/comments?per_page=100" "$(json_array \
    "$(carried_comment 1 'github-actions[bot]' NONE 3001)" \
    "$(carried_comment 2 'github-actions[bot]' NONE 3002)" "$m8")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_called 'gh pr merge'
  refute_called 'curl'
  refute_called 'reason=carried-open'
  assert_called 'gh api POST repos/o/r/pulls/7/reviews' 1
  body="$(fake_last_body 'gh api POST repos/o/r/pulls/7/reviews')"
  assert_contains "$body" '更早的 review 3002 里还有没修完的意见'
  assert_contains "$body" "<!-- pr-guard: carried-reraise head=$H reviews=3002 -->"
}

# iterate 不接 [no-claude] 的 PR：补了那条 review 也没人修，它还会拦着合并、悄悄卡住。
@test "carried: a [no-claude] PR is not asked for a fix round; it parks with the alert" {
  export CODEX_TRIGGER_TOKEN=owner-pat
  fake_route repos/o/r/pulls/7 "$(pr_json | jq '.title = "[no-claude] feat: x"')"
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_route "repos/o/r/issues/7/comments?per_page=100" "$(json_array \
    "$(carried_comment 1 'github-actions[bot]' NONE 3001)")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_called 'gh pr merge'
  refute_called 'gh api POST repos/o/r/pulls/7/reviews'
  body="$(fake_last_body 'gh api POST repos/o/r/issues/7/comments')"
  assert_contains "$body" '标题带 [no-claude]，不自动修'
  assert_contains "$body" "<!-- pr-guard: alert head=$H reason=carried-open until=- -->"
}

@test "carried: a fix-round request that cannot be posted falls back to the alert" {
  export CODEX_TRIGGER_TOKEN=owner-pat
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_route "repos/o/r/issues/7/comments?per_page=100" "$(json_array \
    "$(carried_comment 1 'github-actions[bot]' NONE 3001)")"
  fake_route_fail -X POST "repos/o/r/pulls/7/reviews" 1
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  refute_called 'gh pr merge'
  assert_contains "$output" 'Could not post the review that asks for a fix round'
  body="$(fake_last_body 'gh api POST repos/o/r/issues/7/comments')"
  assert_contains "$body" '请自动修复的那条 review 没发出去'
  assert_contains "$body" "<!-- pr-guard: alert head=$H reason=carried-open until=- -->"
}

@test "carried: once a later fix round closed it, the head merges" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_route "repos/o/r/issues/7/comments?per_page=100" "$(json_array \
    "$(carried_comment 1 'github-actions[bot]' NONE 3001)" \
    "$(carried_comment 2 'github-actions[bot]' NONE 3001 cleared)")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_called "gh pr merge 7 --repo o/r --squash --delete-branch --match-head-commit $H" 1
}

# judge 逐条核过、在主人写的放行标记（M8）里点了名的 review，也算处理过：Claude 判「不用改」
# 交给 judge 放行时，那一轮没推任何东西，没有 M7 来关它。只认主人写的 M8。
@test "carried: a review the judge released by name no longer blocks the merge" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_route "repos/o/r/issues/7/comments?per_page=100" "$(json_array \
    "$(carried_comment 1 'github-actions[bot]' NONE 3001)" \
    "$(gh_comment 2 Melodymaifafa OWNER "放行 <!-- claude-judge-clean: head=$OTHER reviews=3000,3001 -->")")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_called "gh pr merge 7 --repo o/r --squash --delete-branch --match-head-commit $H" 1

  : >"$FAKE_LOG"
  fake_route "repos/o/r/issues/7/comments?per_page=100" "$(json_array \
    "$(carried_comment 1 'github-actions[bot]' NONE 3001)" \
    "$(gh_comment 2 'github-actions[bot]' NONE "放行 <!-- claude-judge-clean: head=$OTHER reviews=3001 -->")")"
  run run_block "$WF" "$STEP"
  refute_called 'gh pr merge'
}

# 关掉的标记只认可信作者：claude[bot] 写一条「已关掉」放不行。反过来，claude[bot] 写的
# 「没推上去」也拦不住合并。
@test "carried: claude[bot] can neither close a carried finding nor open one" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_route "repos/o/r/issues/7/comments?per_page=100" "$(json_array \
    "$(carried_comment 1 'github-actions[bot]' NONE 3001)" \
    "$(carried_comment 2 'claude[bot]' NONE 3001 cleared)")"
  run run_block "$WF" "$STEP"
  refute_called 'gh pr merge'

  : >"$FAKE_LOG"
  fake_route "repos/o/r/issues/7/comments?per_page=100" "$(json_array \
    "$(carried_comment 1 'claude[bot]' NONE 3001)")"
  run run_block "$WF" "$STEP"
  assert_called "gh pr merge 7 --repo o/r --squash --delete-branch --match-head-commit $H" 1
}

# Codex 2026-10-07 的 P1：标记是修复那一轮推不上去之后才发的。新 head 审查通过得快时，
# 合并会赶在旧那轮发标记之前做完。所以合并前先看这个 PR 上有没有修复在跑。
FIX_RUNS="repos/o/r/actions/runs?event=pull_request_review&branch=topic&per_page=100"
fix_run() { # fix_run <status> [workflow name]
  jq -n --arg s "$1" --arg n "${2:-Claude iterates on Codex review}" \
    '{workflow_runs: [{id: 1, name: $n, status: $s, head_branch: "topic"}]}'
}

@test "carried: a fix round still running on the PR holds the merge" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_route "$FIX_RUNS" "$(fix_run in_progress)"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_contains "$output" 'A fix round is still running on this PR'
  # 等了一分钟（3 次 20 秒）才放弃
  assert_called 'sleep 20' 3
  refute_called 'gh pr merge'
  # 还没有可说的：等它收尾，不告警
  refute_called 'curl'
}

# 等的那一分钟里它收尾了、留下了标记：先查 run、后读评论，这条标记一定看得见。
@test "carried: a fix round that settles during the wait and leaves a carry still blocks" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_route "$FIX_RUNS" "$(fix_run queued)" 1
  fake_route "$FIX_RUNS" "$(fix_run completed)" 2
  fake_route "repos/o/r/issues/7/comments?per_page=100" "$(json_array \
    "$(carried_comment 1 'github-actions[bot]' NONE 3001)")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_called 'sleep 20' 1
  assert_contains "$output" 'Unfinished findings from review(s) 3001 are still open'
  refute_called 'gh pr merge'
}

@test "carried: other workflows still running on the branch do not hold the merge" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_route "$FIX_RUNS" "$(fix_run in_progress CI)"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_called "gh pr merge 7 --repo o/r --squash --delete-branch --match-head-commit $H" 1
}

@test "carried: fix rounds that cannot be listed fail closed: no merge" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_route_fail "$FIX_RUNS" 1
  run run_block "$WF" "$STEP"
  assert_equal "$status" 1
  assert_contains "$output" 'Cannot list the fix rounds on this PR'
  refute_called 'gh pr merge'
}

@test "carried: comments that cannot be read fail closed: no merge" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_route_fail "repos/o/r/issues/7/comments?per_page=100" 1
  run run_block "$WF" "$STEP"
  assert_equal "$status" 1
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

# 冲突交给 resolve-conflict 把集成分支合进来，不告警；它解不了才告警 conflict-stuck。
@test "a conflicted PR is handed to resolve-conflict instead of alerting" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_route repos/o/r/pulls/7 "$(pr_json "$H" dirty)"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_equal "$(step_output conflict)" true
  assert_equal "$(step_output head)" "$H"
  refute_called 'curl'
  refute_called 'gh api POST'
  refute_called 'gh pr merge'
}

# 一开就冲突的 PR 上 GitHub 不跑 pull_request 的 CI：不干等到超时报 ci，直接交给 resolve-conflict。
@test "a conflicted PR with no CI checks is handed to resolve-conflict without waiting" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  fake_cli pr_checks '[{"name":"iterate","state":"FAILURE","bucket":"fail","link":"https://github.com/o/r/actions/runs/333/job/1","workflow":"Claude iterates on Codex review"}]'
  fake_route repos/o/r/pulls/7 "$(pr_json "$H" dirty)"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_equal "$(step_output conflict)" true
  assert_equal "$(step_output head)" "$H"
  refute_contains "$output" 'did not settle'
  refute_called 'sleep'
  refute_called 'curl'
  refute_called 'gh api POST'
  refute_called 'gh pr merge'
}

# 还没有检查、也不冲突时照旧等 CI，不交给 resolve-conflict。
@test "no CI checks on a PR without conflicts keeps waiting and alerts ci" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  fake_cli pr_checks '[]'
  fast_sleep 60
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  assert_contains "$output" 'did not settle'
  assert_called "reason=ci until=-" 1
  if step_output conflict >/dev/null; then
    echo "unexpected conflict output: $(step_output conflict)" >&2
    return 1
  fi
}

# ── 合并请求被 GitHub 拒绝 ──

REFUSED='GraphQL: refusing to allow a GitHub App to create or update workflow `.github/workflows/<!-- claude-review-clean: x -->.yml` without `workflows` permission (mergePullRequest)'

@test "a merge refused over a workflow file alerts merge-refused once and fails the run" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_cli_fail pr_merge 1 "$REFUSED"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 1
  assert_called "gh pr merge 7 --repo o/r --squash --delete-branch --match-head-commit $H" 1
  assert_called 'curl' 1
  assert_called 'gh api POST repos/o/r/issues/7/comments' 1
  assert_called "reason=merge-refused until=-" 1
  # 报错原文（含 PR 能控制的文件名）只进日志，不进评论。
  assert_contains "$output" 'refusing to allow a GitHub App'
  refute_contains "$(fake_all_bodies)" '.github/workflows/'
  assert_bodies_inert
}

@test "any other merge failure alerts merge-failed with the run link" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_cli_fail pr_merge 1 'GraphQL: Something went wrong (mergePullRequest)'
  run run_block "$WF" "$STEP"
  assert_equal "$status" 1
  assert_called 'curl' 1
  assert_called "reason=merge-failed until=-" 1
  refute_called "reason=merge-refused"
  assert_contains "$(fake_all_bodies)" 'https://github.com/o/r/actions/runs/111'
  assert_bodies_inert
}

@test "the merge-refused alert is not repeated for the same head" {
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
  fake_cli_fail pr_merge 1 "$REFUSED"
  fake_route "repos/o/r/issues/7/comments?per_page=100" \
    "$(json_array "$(gh_comment 1 'github-actions[bot]' NONE "合不了。

$(m6_marker "$H" merge-refused)")")"
  run run_block "$WF" "$STEP"
  assert_equal "$status" 1
  refute_called 'curl'
  refute_called 'gh api POST'
}

# 成功合并的一轮里读了几次 PR；用来把「合并失败之后」那一次读换成别的状态。
clean_signoff() {
  rm -rf "$FAKE_DIR"
  setup
  path_d "$(gh_comment 600 Melodymaifafa OWNER "$(m4_body "$H")")"
  green_checks
}

@test "a failed merge on a PR that got merged or moved on meanwhile is not an alert" {
  local n i after
  clean_signoff
  run run_block "$WF" "$STEP"
  assert_equal "$status" 0
  n="$(fake_count 'gh api GET repos/o/r/pulls/7 ::')"
  [ "$n" -gt 0 ]
  for after in "$(pr_json "$H" clean true)" "$(pr_json "$OTHER")"; do
    clean_signoff
    fake_cli_fail pr_merge 1 'GraphQL: Head branch was modified (mergePullRequest)'
    for i in $(seq 1 "$n"); do fake_route repos/o/r/pulls/7 "$(pr_json)" "$i"; done
    fake_route repos/o/r/pulls/7 "$after" "$((n + 1))"
    run run_block "$WF" "$STEP"
    assert_equal "$status" 0
    assert_contains "$output" 'nothing to report'
    refute_called 'curl'
    refute_called 'gh api POST'
  done
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
