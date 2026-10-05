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

# ---------- 只答本次 run 自己那些进程的 ps（MEL-304） ----------

# 验证正文那道清点按运行用户问「名下有谁」。本机上那个名下还有隔壁 worker 的
# `bats tests/`、macOS 按需拉起来的服务、开着的桌面应用，它们会被当成「验证命令留
# 下的」，整套测试随机变红。tests 里那份 ps（tests/test_helper/sweep-bin/ps）只答本次
# run 自己的进程。
# 下面四条钉住边界。最要紧的是第二条「逃出去的残留必须照答」—— 这条规则的失败方向
# 是少报，少报一个，那几条「必须红」的测试就假绿。
# 进程表、「我们是谁」、本次标记、uid 全是喂进去的，所以在哪台机器上都是同一个答案。
sweep_ps_with_table() { # sweep_ps_with_table <我们是谁的 pid> <本次 run 的标记> <args…>
  local fake="$BATS_TEST_TMPDIR/table-ps"
  cat >"$fake" <<'EOF'
#!/bin/sh
# 两种问法答同一张表：-A 是快照（带 ppid），别的是清点自己要的格式。
#   1    launchd
#   50   我们和隔壁共同的那个祖先（跑这一轮的那个 shell）—— 往上走到它就等于把隔壁
#        整棵树认成自己，所以它必须进不了「自己」
#   100  隔壁那次 run 的 bats，101 它的测试进程，201 它那一步的 shell，202 它的子进程
#   300  我们这次 run 的 bats，301 我们这一步的 shell（清点从这儿问出来），302 它的子进程
#   400  我们的逃逸残留：被过继给 init，argv 里还带着本次 run 的临时目录
#   500  macOS 按需拉起来的服务，600 机器上随便一个别的进程
case " $* " in
  *" -A "*) printf '%s\n' \
      '    1     0 /sbin/launchd' \
      '   50     1 bash /usr/local/bin/run-the-suites' \
      '  100    50 bash /opt/homebrew/libexec/bats-core/bats-exec-suite --x' \
      '  101   100 bash /opt/homebrew/libexec/bats-core/bats-exec-test --x' \
      '  201   101 bash /tmp/bats-run-theirs/block-Verify.sh' \
      '  202   201 git status' \
      '  300    50 bash /opt/homebrew/libexec/bats-core/bats-exec-test --mine' \
      '  301   300 bash /tmp/bats-run-mine/block-Verify.sh' \
      '  302   301 git status' \
      '  400     1 /bin/sh /tmp/bats-run-mine/escapee.sh' \
      '  500     1 /usr/libexec/networkserviceproxy' \
      '  600     1 /Users/me/.local/bin/some-agent --model x' ;;
  *) printf '%s\n' \
      '    1 /sbin/launchd' \
      '   50 bash /usr/local/bin/run-the-suites' \
      '  100 bash /opt/homebrew/libexec/bats-core/bats-exec-suite --x' \
      '  101 bash /opt/homebrew/libexec/bats-core/bats-exec-test --x' \
      '  201 bash /tmp/bats-run-theirs/block-Verify.sh' \
      '  202 git status' \
      '  300 bash /opt/homebrew/libexec/bats-core/bats-exec-test --mine' \
      '  301 bash /tmp/bats-run-mine/block-Verify.sh' \
      '  302 git status' \
      '  400 /bin/sh /tmp/bats-run-mine/escapee.sh' \
      '  500 /usr/libexec/networkserviceproxy' \
      '  600 /Users/me/.local/bin/some-agent --model x' ;;
esac
EOF
  chmod +x "$fake"
  GHWF_SWEEP_REAL_PS="$fake" GHWF_SWEEP_SELF="$1" GHWF_SWEEP_RUN_TAG="$2" \
    GHWF_SWEEP_SELF_UID=501 "$SWEEP_BIN_DIR/ps" "${@:3}"
}

@test "the scoped ps answers this step and its children, and no outsider" {
  run sweep_ps_with_table 301 /tmp/bats-run-mine -U 501 -o pid=,args=
  assert_equal "$status" 0
  assert_contains "$output" '301 bash /tmp/bats-run-mine/block-Verify.sh'
  assert_contains "$output" '302 git status'
  # 隔壁那次 run 整棵树、共同的那个祖先、macOS 的服务、机器上随便一个别的进程
  refute_contains "$output" 'bats-exec-suite --x'
  refute_contains "$output" 'bats-run-theirs'
  refute_contains "$output" '202 git status'
  refute_contains "$output" 'run-the-suites'
  refute_contains "$output" 'networkserviceproxy'
  refute_contains "$output" 'some-agent'
  refute_contains "$output" 'launchd'
}

@test "the scoped ps still answers a leftover that escaped its process group" {
  # 这一条是整份筛选的要害。逃出去的残留换了会话、关光了描述符、被过继给 init，
  # 父子链上认不回来，只剩 argv 里那个本次 run 的临时目录。少报它 = 清点看不见
  # 「验证命令留下了活进程」= 那几条「必须红」的测试假绿，而假绿看不见。
  run sweep_ps_with_table 301 /tmp/bats-run-mine -U 501 -o pid=,args=
  assert_equal "$status" 0
  assert_contains "$output" '400 /bin/sh /tmp/bats-run-mine/escapee.sh'
}

@test "the scoped ps gives each run only its own side of the same table" {
  # 对称的那一半：换成隔壁那次 run 来问（它那一步的 shell 是 201，标记是它的目录），
  # 答的就只有它那一边。两次问同一张表，两边各自看不见对方 —— 这就是「同机并发两套
  # 测试互不干扰」在筛选这一层的全部含义。
  run sweep_ps_with_table 201 /tmp/bats-run-theirs -U 501 -o pid=,args=
  assert_equal "$status" 0
  assert_contains "$output" '201 bash /tmp/bats-run-theirs/block-Verify.sh'
  assert_contains "$output" '202 git status'
  refute_contains "$output" 'bats-run-mine'
  refute_contains "$output" '302 git status'
}

@test "the scoped ps falls back to the whole machine instead of answering empty" {
  # 认不出本次 run 就原样交出全机那一份：噪声回来、并发重新变红，看得见、好诊断。
  # 反过来（交一份空的）会让这道门静默放行 —— 那是唯一不能接受的失败方向。
  run sweep_ps_with_table 101 /tmp/nowhere -U 501 -o pid=,args=
  assert_equal "$status" 0
  assert_contains "$output" 'networkserviceproxy'
  assert_contains "$output" '302 git status'
  # 按进程组那一下只看我们自己那个组号；问别的 uid 的是 runner 上那个专用账号。
  # 两种本来都不会数到外人，所以一个字都不许改。
  run sweep_ps_with_table 301 /tmp/bats-run-mine -e -o pgid=,pid=,stat=
  assert_equal "$status" 0
  assert_contains "$output" 'networkserviceproxy'
  run sweep_ps_with_table 301 /tmp/bats-run-mine -U 4242 -o pid=,args=
  assert_equal "$status" 0
  assert_contains "$output" 'bats-run-theirs'
}
