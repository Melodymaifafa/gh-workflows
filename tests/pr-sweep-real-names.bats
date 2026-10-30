#!/usr/bin/env bats
# 主人 Mac 上的巡检日志（SWEEP_LOG_REAL_NAMES=1）：私有仓库也写真名和 PR 号，gh 报错照常输出；
# 不设（pr-sweeper.yml）就跟以前一样只写 repo-<hash>，gh 报错吞掉。

load test_helper/common

H=1a7e81f6b5f27f0a1dbc33c6fafda1bb86f1483d
R=Melodymaifafa/private-caller
# 开关关着时日志里该有的标签：repo-<HMAC 前 8 位>。
LABEL="repo-$(printf '%s' "$R" | openssl dgst -sha256 -hmac owner-pat | awk '{print $NF}' | cut -c1-8)"

setup() {
  setup_fake_env
  export OWNER=Melodymaifafa SWEEP_MODE=live ONLY_REPOS=private-caller GH_TOKEN=owner-pat
  NOW_EPOCH="$(jq -n '"2026-09-18T12:00:00Z" | fromdateiso8601')"
  export NOW_EPOCH
  unset PUSHOVER_TOKEN PUSHOVER_USER SWEEP_LOG_REAL_NAMES
  fake_route "user/repos?affiliation=owner&per_page=100" sweep/user-repos.json
  fake_route "repos/$R/contents/.github/workflows/codex-approved-merge.yml" \
    "$(printf '%s\n' 'jobs:' '  merge:' '    uses: Melodymaifafa/gh-workflows/.github/workflows/codex-approved-merge.yml@v1')"
  fake_route "repos/Melodymaifafa/gh-workflows/issues?state=open&creator=Melodymaifafa&per_page=100" '[]'
  # private-caller 只有 PR #7，空闲 15 小时、没人碰过：规则 5 会去 kick。
  local pr
  pr="$(jq -n --arg h "$H" --arg r "$R" --arg u "$(jq -nr --argjson t "$((NOW_EPOCH - 54000))" '$t | todate')" '{
    number: 7, state: "open", draft: false, title: "feat: something", merged: false, mergeable_state: "clean",
    updated_at: $u, html_url: "https://github.com/\($r)/pull/7",
    head: {sha: $h, repo: {full_name: $r}}, base: {ref: "develop", repo: {full_name: $r}}}')"
  fake_route "repos/$R/pulls?state=open&per_page=100" "$(json_array "$pr")"
  fake_route "repos/$R/pulls/7" "$pr"
  fake_route "repos/$R/issues/7/comments?per_page=100" '[]'
  fake_route "repos/$R/pulls/7/reviews?per_page=100" '[]'
}

# sweep_both：开关开着跑一遍、关着跑一遍，日志（含 stderr）和摘要分别放进 $on / $off。
sweep_both() {
  : >"$GITHUB_STEP_SUMMARY"
  SWEEP_LOG_REAL_NAMES=1 run bash "$REPO_ROOT/scripts/pr-sweep.sh"
  on="$output$(cat "$GITHUB_STEP_SUMMARY")"
  : >"$GITHUB_STEP_SUMMARY"
  run bash "$REPO_ROOT/scripts/pr-sweep.sh"
  off="$output$(cat "$GITHUB_STEP_SUMMARY")"
}

@test "switch on: a private repo shows as owner/repo#N with its SHA, never as a label" {
  sweep_both
  assert_contains "$on" "$R#7 (${H:0:7}): idle="
  assert_contains "$on" "kicked $R#7 (${H:0:7})"
  refute_contains "$on" "repo-"
}

@test "switch off: a private repo shows only its repo-<hash> label" {
  sweep_both
  assert_contains "$off" "$LABEL: idle="
  assert_contains "$off" "kicked $LABEL"
  refute_contains "$off" "private-caller"
  refute_contains "$off" "#7"
  refute_contains "$off" "${H:0:7}"
}

@test "a broken PR: the warning names the real PR and gh's error shows only with the switch on" {
  # 没有评论 fixture → 假 gh 在 stderr 报错，报错里带仓库名。
  rm "$FAKE_GH_DIR/api/GET/$(fake_route_key "repos/$R/issues/7/comments?per_page=100").json"
  sweep_both
  assert_contains "$on" "::warning::$R#7 巡检出错"
  assert_contains "$on" "FAKE: no fixture for 'gh api GET repos/$R/issues/7/comments"
  refute_contains "$on" "repo-"
  assert_contains "$off" "::warning::$LABEL 巡检出错"
  refute_contains "$off" "FAKE"
  refute_contains "$off" "private-caller"
}

@test "listing PRs fails: the warning names the repo and gh's error shows only with the switch on" {
  fake_route_fail "repos/$R/pulls?state=open&per_page=100" 1 '{"message":"Not Found"}'
  sweep_both
  assert_contains "$on" "::warning::$R 列 PR 失败"
  assert_contains "$on" "gh: fake HTTP error"
  refute_contains "$on" "repo-"
  assert_contains "$off" "::warning::$LABEL 列 PR 失败"
  refute_contains "$off" "fake HTTP error"
  refute_contains "$off" "private-caller"
}

@test "the merge stub is unreadable: the warning names the repo and gh's error shows only with the switch on" {
  fake_route_fail "repos/$R/contents/.github/workflows/codex-approved-merge.yml" 1 '{"message":"x","status":"403"}'
  sweep_both
  assert_contains "$on" "读不到合并调用桩"
  assert_contains "$on" "：$R"
  assert_contains "$on" "gh: fake HTTP error"
  refute_contains "$on" "repo-"
  assert_contains "$off" "：$LABEL"
  refute_contains "$off" "fake HTTP error"
  refute_contains "$off" "private-caller"
}

@test "the Mac loop turns the switch on for its sweep, and no workflow sets it" {
  local mac="$BATS_TEST_TMPDIR/mac" stubs="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$mac" "$stubs"
  cp "$REPO_ROOT/scripts/pr-sweep-local.sh" "$mac/"
  # 替身 pr-sweep.sh：只报它拿到的开关。替身 sleep 退出非 0，跑完一轮循环就停。
  printf '%s\n' '#!/usr/bin/env bash' 'echo "real=${SWEEP_LOG_REAL_NAMES:-unset}"' >"$mac/pr-sweep.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$stubs/sleep"
  chmod +x "$mac/pr-sweep.sh" "$stubs/sleep"
  fake_route "repos/Melodymaifafa/gh-workflows/actions/variables/SWEEP_MODE" '{"value":"live"}'
  echo 'CODEX_TRIGGER_TOKEN=x' >"$BATS_TEST_TMPDIR/secrets.env"
  GH_WORKFLOWS_SECRETS="$BATS_TEST_TMPDIR/secrets.env" PATH="$stubs:$PATH" run bash "$mac/pr-sweep-local.sh"
  assert_contains "$output" "real=1"

  run grep -rn SWEEP_LOG_REAL_NAMES "$REPO_ROOT/.github"
  assert_equal "$status" 1
}
