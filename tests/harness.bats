#!/usr/bin/env bats
# 假 GitHub 环境自己的测试。假命令要是悄悄放水，别的测试全都会假绿。

load test_helper/common

setup() {
  setup_fake_env
}

@test "gh api serves a GET fixture by route, query string included" {
  fake_route "repos/o/r/issues/7/comments?per_page=100" codex/quota-comment.json
  run gh api "repos/o/r/issues/7/comments?per_page=100" --jq .user.login
  assert_equal "$status" 0
  assert_equal "$output" 'chatgpt-codex-connector[bot]'
  assert_called "gh api GET repos/o/r/issues/7/comments?per_page=100" 1
}

@test "gh api with a leading slash hits the same fixture" {
  fake_route repos/o/r/pulls/7 '{"head":{"sha":"abc"}}'
  run gh api /repos/o/r/pulls/7 -q .head.sha
  assert_equal "$output" abc
}

@test "gh api replays a sequence and repeats the last response" {
  fake_route repos/o/r/pulls/7 '{"n":1}' 1
  fake_route repos/o/r/pulls/7 '{"n":2}' 2
  out=""
  for _ in 1 2 3 4; do out="$out$(gh api repos/o/r/pulls/7 --jq .n)"; done
  assert_equal "$out" 1222
  assert_called "gh api GET repos/o/r/pulls/7" 4
}

@test "sequence counters are per route and per method" {
  fake_route repos/o/r/a '"a1"' 1
  fake_route repos/o/r/a '"a2"' 2
  fake_route repos/o/r/b '"b"'
  assert_equal "$(gh api repos/o/r/a --jq .)" a1
  assert_equal "$(gh api repos/o/r/b --jq .)" b
  assert_equal "$(gh api repos/o/r/a --jq .)" a2
}

@test "--paginate --slurp wraps a single-page fixture as an array of pages" {
  fake_route "repos/o/r/pulls/7/reviews?per_page=100" "$(json_array \
    "$(gh_review 1 'chatgpt-codex-connector[bot]' NONE deadbeef 'x')")"
  run gh api --paginate --slurp "repos/o/r/pulls/7/reviews?per_page=100"
  assert_equal "$(jq -r '.[0][0].commit_id' <<<"$output")" deadbeef
  run gh api --paginate "repos/o/r/pulls/7/reviews?per_page=100" --jq '.[0].user.type'
  assert_equal "$output" Bot
}

@test "unknown GET route fails loudly with exit 97" {
  run gh api repos/o/r/pulls/404
  assert_equal "$status" 97
  assert_contains "$output" "no fixture for 'gh api GET repos/o/r/pulls/404'"
}

@test "unsupported gh invocations and flags fail loudly" {
  run gh codespace list
  assert_equal "$status" 97
  run gh api repos/o/r --template '{{.id}}'
  assert_equal "$status" 97
  run gh pr view 7 --json headRefOid
  assert_equal "$status" 97
  assert_contains "$output" "no fixture for 'gh pr view'"
}

@test "fake refuses to run outside setup_fake_env" {
  run env -u FAKE_DIR -u FAKE_GH_DIR -u FAKE_LOG "$FAKE_BIN_DIR/gh" api repos/o/r
  assert_equal "$status" 97
}

@test "writes default to {} and log the method, route, body and token" {
  run env GH_TOKEN=pat-token gh api -X POST repos/o/r/issues/7/comments -f body="$(m4_body abc)"
  assert_equal "$status" 0
  assert_equal "$output" '{}'
  assert_called "gh api POST repos/o/r/issues/7/comments ::" 1
  assert_called "claude-review-clean: abc"
  assert_called "[token=pat-token]"
  assert_equal "$(fake_last_body 'issues/7/comments')" "$(m4_body abc)"
}

@test "fields without -X mean POST, like real gh; GET fields become the query string" {
  gh api repos/o/r/issues/7/comments -f body=hi >/dev/null
  assert_called "gh api POST repos/o/r/issues/7/comments"
  fake_route "search/issues?q=is:open" '{"total_count":3}'
  run gh api -X GET search/issues -f q=is:open --jq .total_count
  assert_equal "$output" 3
}

@test "--input - reads the JSON body from stdin" {
  fake_route -X POST repos/o/r/pulls/7/reviews '{"id":42}'
  run bash -c 'jq -n --arg b "review text" "{event:\"COMMENT\",commit_id:\"abc\",body:\$b}" |
    gh api -X POST repos/o/r/pulls/7/reviews --input - --jq .id'
  assert_equal "$output" 42
  assert_equal "$(fake_last_body 'pulls/7/reviews')" 'review text'
  assert_called '"commit_id":"abc"'
}

@test "fake_route_fail makes a route exit non-zero with a body" {
  fake_route_fail repos/o/r 1 '{"message":"Bad credentials"}'
  run gh api repos/o/r --jq .id
  assert_equal "$status" 1
  assert_contains "$output" 'Bad credentials'
}

@test "gh pr comment logs the body and prints a comment URL by default" {
  run gh pr comment 7 --repo o/r --body "$(m1_body abc 2)"
  assert_equal "$status" 0
  assert_contains "$output" 'https://github.com/o/r/pull/7#issuecomment-'
  assert_equal "$(fake_last_body 'gh pr comment 7')" "$(printf '@codex review\n\n<!-- codex-review-head: abc -->\n<!-- fix-round: 2 -->')"
}

@test "gh pr view applies --jq to a canned object; pr merge and workflow succeed silently" {
  fake_cli pr_view '{"headRefOid":"abc","state":"OPEN"}'
  run gh pr view 7 --repo o/r --json headRefOid --jq .headRefOid
  assert_equal "$output" abc
  run gh pr merge 7 --repo o/r --squash --delete-branch --match-head-commit abc
  assert_equal "$status" 0
  run gh workflow enable pr-sweeper.yml --repo o/r
  assert_equal "$status" 0
  assert_called 'gh pr merge 7 --repo o/r --squash --delete-branch --match-head-commit abc' 1
}

@test "fake_cli_fail and cli sequences" {
  fake_cli_fail pr_checks 8 'ci  fail  1m  https://x' 1
  fake_cli pr_checks 'ci  pass  1m  https://x' 2
  run gh pr checks 7 --repo o/r
  assert_equal "$status" 8
  run gh pr checks 7 --repo o/r
  assert_equal "$status" 0
  assert_contains "$output" pass
}

@test "curl logs the Pushover call with its message and succeeds" {
  run curl -sf -X POST https://api.pushover.net/1/messages.json \
    --form-string "token=t" --form-string "user=u" --form-string "message=额度用完了"
  assert_equal "$status" 0
  assert_contains "$output" '"status":1'
  assert_called 'api.pushover.net'
  assert_equal "$(fake_last_body pushover)" '额度用完了'
}

@test "curl can be made to fail" {
  echo 22 >"$FAKE_GH_DIR/curl.exit"
  run curl -sf https://api.pushover.net/1/messages.json
  assert_equal "$status" 22
}

@test "sleep is a logged no-op" {
  SECONDS=0
  run sleep 30
  assert_equal "$status" 0
  assert_called 'sleep 30' 1
  [ "$SECONDS" -lt 5 ] || { echo "sleep really slept" >&2; return 1; }
}

@test "date honors FAKE_NOW and sleep advances the fake clock" {
  export FAKE_NOW=2026-09-18T08:00:00Z
  assert_equal "$(date -u +%FT%TZ)" 2026-09-18T08:00:00Z
  assert_equal "$(date +%s)" 1789718400
  sleep 30
  sleep 1m
  assert_equal "$(date -u +%FT%TZ)" 2026-09-18T08:01:30Z
  assert_equal "$(fake_now_epoch)" 1789718490
}

@test "date -d parses ISO 8601 and @epoch without FAKE_NOW (portable to macOS)" {
  assert_equal "$(date -d 2026-08-22T07:34:00Z +%s)" 1787384040
  assert_equal "$(date -d 2026-08-22T07:34:00.123Z +%s)" 1787384040
  assert_equal "$(date -u -d @1787569200 '+%F %H:%M')" '2026-08-24 11:00'
  assert_equal "$(TZ=Asia/Shanghai date -d @1787569200 '+%m-%d %H:%M')" '08-24 19:00'
}

@test "date without FAKE_NOW delegates to the real clock" {
  now="$(date +%s)"
  [ "$now" -gt 1789000000 ] || { echo "got $now" >&2; return 1; }
}

@test "run_block runs a real step under -eo pipefail and exposes GITHUB_OUTPUT" {
  cat >"$BATS_TEST_TMPDIR/wf.yml" <<'YML'
jobs:
  j:
    steps:
      - name: Demo
        env:
          X: y
        run: |
          head="$(gh api repos/o/r/pulls/7 --jq .head.sha)"
          echo "head=$head" >>"$GITHUB_OUTPUT"
          {
            echo 'note<<EOF'
            echo 'line 1'
            echo 'line 2'
            echo 'EOF'
          } >>"$GITHUB_OUTPUT"
          echo done
      - name: Fails
        run: |
          false | cat
          echo unreachable
      - name: Expr
        run: |
          echo "${{ github.event.pull_request.number }}"
YML
  fake_route repos/o/r/pulls/7 '{"head":{"sha":"abc"}}'
  run run_block "$BATS_TEST_TMPDIR/wf.yml" Demo
  assert_equal "$status" 0
  assert_equal "$(step_output head)" abc
  assert_equal "$(step_output note)" "$(printf 'line 1\nline 2')"

  run run_block "$BATS_TEST_TMPDIR/wf.yml" Fails
  assert_equal "$status" 1
  refute_contains "$output" unreachable

  run run_block "$BATS_TEST_TMPDIR/wf.yml" Expr
  assert_equal "$status" 98
  run run_block "$BATS_TEST_TMPDIR/wf.yml" 'No such step'
  assert_equal "$status" 98
}

@test "fixtures parse and forged markers are never trusted authors" {
  for f in "$FIXTURES_DIR"/*/*.json; do
    jq -e . "$f" >/dev/null || { echo "bad JSON: $f" >&2; return 1; }
  done
  run jq -r '[.user.login, .author_association] | join(" ")' "$FIXTURES_DIR/forged/claude-bot-clean-comment.json"
  assert_equal "$output" 'claude[bot] NONE'
  run jq -r '.[] | select(.type == "result") | .api_error_status' "$FIXTURES_DIR/sdk/exec-429-weekly-limit.json"
  assert_equal "$output" 429
  run jq -r '.[] | select(.type == "rate_limit_event") | .rate_limit_info.resetsAt' "$FIXTURES_DIR/sdk/exec-429-weekly-limit.json"
  assert_equal "$output" 1787569200
}
