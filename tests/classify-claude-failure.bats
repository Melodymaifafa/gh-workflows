#!/usr/bin/env bats
# scripts/classify-claude-failure.sh —— 把 Claude 的失败分成 quota / business。
# 两种误判的代价不对称：额度失败误判成 business，job 红了、人看一眼就好；业务
# 失败误判成 quota，则是一个本该红的 PR 换个模型再改一轮，把真问题埋进绿勾里。
# 所以下面每条 business 用例都是「必须不换人」的硬约束。

load test_helper/common

classify() {
  printf '%s\n' "$1" | "$SCRIPTS/classify-claude-failure.sh"
}

verdict() {
  printf '%s\n' "$1" | sed -n 's/^class=//p'
}

why() {
  printf '%s\n' "$1" | sed -n 's/^reason=//p'
}

@test "订阅额度用尽 counts as a provider failure" {
  out="$(classify 'error_during_execution true Claude AI usage limit reached|1756089600')"
  assert_equal "$(verdict "$out")" quota
  assert_contains "$(why "$out")" 'usage limit reached'
}

@test "a 429 rate limit counts as a provider failure" {
  out="$(classify 'API Error 429 rate_limit_error: too many requests')"
  assert_equal "$(verdict "$out")" quota
}

@test "an expired or rejected token counts as a provider failure" {
  out="$(classify 'authentication_error: OAuth token has expired')"
  assert_equal "$(verdict "$out")" quota
}

@test "the provider being down counts as a provider failure" {
  out="$(classify 'API Error 529 overloaded_error: service unavailable')"
  assert_equal "$(verdict "$out")" quota
}

@test "an API 500 internal error counts as a provider failure" {
  out="$(classify 'API Error: 500 {"type":"error","error":{"type":"api_error","message":"Internal server error"}}')"
  assert_equal "$(verdict "$out")" quota
}

@test "matching is case-insensitive" {
  # 大小写不敏感，但位置照样要求在行首：provider 的报错自己占一行，散文里
  # 出现同样的词不算（见文件末尾那组「散文不能买到一次换人」）。
  out="$(classify 'INSUFFICIENT_QUOTA: this key has no credit left')"
  assert_equal "$(verdict "$out")" quota
}

@test "a failing test suite is a business failure — no handover" {
  out="$(classify 'error_during_execution true 3 failed, 41 passed in pytest; I could not make them pass')"
  assert_equal "$(verdict "$out")" business
}

@test "a broken build is a business failure — no handover" {
  out="$(classify 'error_during_execution true npm run build exited 1: TS2345 type error in src/app.ts')"
  assert_equal "$(verdict "$out")" business
}

@test "running out of turns is a business failure — no handover" {
  out="$(classify 'error_max_turns true Reached maximum turns without finishing the fix')"
  assert_equal "$(verdict "$out")" business
}

@test "no diagnosable output fails closed to business" {
  out="$(classify '')"
  assert_equal "$(verdict "$out")" business
  assert_contains "$(why "$out")" 'no diagnosable output'
}

@test "whitespace-only output fails closed to business" {
  out="$(classify '   ')"
  assert_equal "$(verdict "$out")" business
}

@test "a missing file fails closed to business instead of erroring" {
  run "$SCRIPTS/classify-claude-failure.sh" "$BATS_TEST_TMPDIR/does-not-exist.txt"
  assert_equal "$status" 0
  assert_contains "$output" 'class=business'
}

@test "the verdict is read from a file when one is given" {
  printf 'API Error 401 unauthorized\n' >"$BATS_TEST_TMPDIR/diag.txt"
  run "$SCRIPTS/classify-claude-failure.sh" "$BATS_TEST_TMPDIR/diag.txt"
  assert_equal "$status" 0
  assert_contains "$output" 'class=quota'
}

@test "the verdict also lands in GITHUB_OUTPUT when the workflow set one" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  : >"$GITHUB_OUTPUT"
  printf 'Claude AI usage limit reached\n' | "$SCRIPTS/classify-claude-failure.sh" >/dev/null
  assert_contains "$(cat "$GITHUB_OUTPUT")" 'class=quota'
}

@test "a review body quoting a quota error is not what the classifier reads" {
  # 分类器只拿到「这次运行的终态字段」，拿不到对话记录 —— 否则 review 正文里
  # 抄一句额度报错就能骗出一次换人。这里守的是调用方的裁剪结果本身。
  out="$(classify 'error_during_execution true the reviewer wrote a comment about handling errors politely')"
  assert_equal "$(verdict "$out")" business
}

# 下面这组守的是「认字不能太宽」：判据只认 provider 真吐出来的报错结构。
# `.result` 是 Claude 自己写的一段自然语言总结，散文里出现同样的词不算数 ——
# 否则评审正文（外部输入）里写一句 503，Claude 复述一遍，就换出一次持写权限
# token 的接管。

@test "a downstream 503 quoted in a test report is a business failure — no handover" {
  out="$(classify 'error_during_execution true 集成测试打下游服务返回 503 Service Unavailable，我修不好')"
  assert_equal "$(verdict "$out")" business
}

@test "a bare service unavailable in prose is a business failure — no handover" {
  out="$(classify 'error_during_execution true the staging service was unavailable, status 503, so the smoke test failed')"
  assert_equal "$(verdict "$out")" business
}

@test "a test asserting on 401 unauthorized is a business failure — no handover" {
  out="$(classify 'error_during_execution true the auth suite expected 401 unauthorized but got 200')"
  assert_equal "$(verdict "$out")" business
}

@test "our own rate limit guard tripping is a business failure — no handover" {
  out="$(classify 'error_during_execution true the load test tripped our own rate limit guard')"
  assert_equal "$(verdict "$out")" business
}

@test "a test name containing a provider error code is a business failure — no handover" {
  out="$(classify 'error_during_execution true test_rate_limit_error still fails after three attempts')"
  assert_equal "$(verdict "$out")" business
}

# 下面这几段文字原来挂在 `<subtype> <is_error> ` 前缀后面断言 quota —— 那个位置
# 放的是模型写的 `.result`，留着等于认可「散文可以买到一次换人」，跟本轮要堵的洞
# 是同一件事（MEL-250 第 2 轮）。证据因此搬到 runner 写的裸行上：runner 从
# execution_file 的 api_error_status 把状态码单独写成一行（Decide the takeover），
# 真的 provider 失败照样认得出来，只是来源换成了模型伪造不了的那个。

@test "a structured API error body still counts as a provider failure" {
  out="$(classify 'API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"too many requests"}}')"
  assert_equal "$(verdict "$out")" quota
}

@test "the same API error body inside the model's summary is not evidence" {
  out="$(classify 'error_during_execution true API Error: 429 {"type":"error","error":{"type":"rate_limit_error"}}')"
  assert_equal "$(verdict "$out")" business
}

@test "the provider being overloaded still counts as a provider failure" {
  out="$(classify 'API Error: 503 upstream connect error')"
  assert_equal "$(verdict "$out")" quota
}

@test "an exhausted credit balance counts as a provider failure" {
  out="$(classify 'Your credit balance is too low to access the Anthropic API')"
  assert_equal "$(verdict "$out")" quota
  assert_contains "$(why "$out")" 'credit balance is too low'
}

@test "the usage-limit sentinel counts on a later line too" {
  # 这一种是例外：固定的一整句、独占一行才算 —— 有多个终态对象时它不一定排在
  # 第一行，所以不能只看前导裸行。
  out="$(printf 'error_during_execution true I started on the failing test\nerror_during_execution true Claude AI usage limit reached|1756089600\n' | "$SCRIPTS/classify-claude-failure.sh")"
  assert_equal "$(verdict "$out")" quota
}

# ---------------------------------------------------------------------------
# 散文不能买到一次换人（MEL-250 F2）。
#
# 旧正则的前缀 `(^|[^a-zA-Z])` 只要求这些字样前面不是字母 —— 一个空格就满足，
# 于是 `API Error: 429` / `overloaded_error` 出现在句子中间照样命中。Claude 把
# 一次业务失败总结成下面任何一句，auto 模式就会换 Codex 接手，而票面要求业务
# 失败不回退、job 必须红。下面六条是审核记录第四节实测过的原话，不是造的。
# ---------------------------------------------------------------------------

@test "prose quoting API Error: 429 while describing a failing test is business" {
  out="$(classify 'the failing test expects API Error: 429 from the stub and I could not make it pass')"
  assert_equal "$(verdict "$out")" business
}

@test "prose quoting authentication_error while describing a fixture is business" {
  out="$(classify 'the fixture asserts error.type authentication_error; assertion still fails')"
  assert_equal "$(verdict "$out")" business
}

@test "prose quoting overloaded_error while describing a unit test is business" {
  out="$(classify 'unit test test_rate_limit_error failed: expected overloaded_error handling')"
  assert_equal "$(verdict "$out")" business
}

@test "a downstream 503 in an integration test report is business" {
  out="$(classify 'downstream returned 503 Service Unavailable in the integration test, could not fix')"
  assert_equal "$(verdict "$out")" business
}

@test "a bare provider error line on its own is still quota" {
  out="$(classify 'API Error: 429')"
  assert_equal "$(verdict "$out")" quota
}

@test "the usage-limit sentinel on its own is still quota" {
  out="$(classify 'Claude AI usage limit reached|1756089600')"
  assert_equal "$(verdict "$out")" quota
}

@test "the same three sentences stay business after the caller prefixes the terminal fields" {
  # 调用方把终态字段拼成 `<subtype> <is_error> <result>` 一行再喂进来；前缀被
  # 允许，但前缀后面还是散文，判定不能因此翻面。
  for sentence in \
    'the failing test expects API Error: 429 from the stub and I could not make it pass' \
    'the fixture asserts error.type authentication_error; assertion still fails' \
    'unit test test_rate_limit_error failed: expected overloaded_error handling'; do
    out="$(classify "error_during_execution true $sentence")"
    assert_equal "$(verdict "$out")" business
  done
}

# ---------------------------------------------------------------------------
# 模型写的总结跨多行时，散文照样不能买到一次换人（MEL-250 第 2 轮）。
#
# 调用方把每个终态对象拼成 `<subtype> <is_error> <result 的第一行>` 一行，
# `.result` 的第 2 行起原样跟在后面、不带任何前缀 —— markdown 小结、分条列举
# 都是常态。所以「锚到行首」还不够：新起的那一行只要正好以额度报错的字样开头
# 就照样命中，一次本该打红的业务失败又被判成额度耗尽、换人再改一轮。
# 可信的额度证据只有 runner 自己从结构化字段读出来写的裸行。
# ---------------------------------------------------------------------------

@test "a later line of a multi-line summary starting with API Error is business" {
  out="$(printf '%s\n' \
    'error_during_execution true I could not fix the failing test.' \
    'API Error: 429 is what the mock is supposed to raise, and the assertion still fails.' \
    'Giving up after 3 attempts.' | "$SCRIPTS/classify-claude-failure.sh")"
  assert_equal "$(verdict "$out")" business
}

@test "a later line of a multi-line summary starting with overloaded_error is business" {
  out="$(printf '%s\n' \
    'error_during_execution true Could not get the suite green.' \
    'overloaded_error is the case the new test covers; my handler still returns 500.' \
    | "$SCRIPTS/classify-claude-failure.sh")"
  assert_equal "$(verdict "$out")" business
}

@test "a multi-line summary whose own first line starts with a marker is business" {
  # 第一行也是模型写的散文，只是被拼上了调用方的前缀 —— 同样不算证据。
  out="$(printf '%s\n' \
    'error_during_execution true API Error: 429 is what the mock raises on purpose' \
    'and the assertion still fails.' | "$SCRIPTS/classify-claude-failure.sh")"
  assert_equal "$(verdict "$out")" business
}

@test "the usage-limit sentence quoted mid-prose is a business failure — no handover" {
  # 这个仓库自己的测试夹具里就有一模一样的字符串（见本文件前面几条用例）；
  # Claude 描述一次相关的失败测试时完全可能原样引用它，那不是额度证据。
  out="$(printf '%s\n' \
    'error_during_execution true the fixture asserts on this exact line:' \
    'Claude AI usage limit reached' \
    'and the test still fails after my fix.' | "$SCRIPTS/classify-claude-failure.sh")"
  assert_equal "$(verdict "$out")" business
}

@test "the runner's own structured line outranks the prose that follows it" {
  # runner 把 SDK 判定的状态码写成裸行放在最前面（Decide the takeover 干的），
  # 那一行是唯一伪造不了的额度证据，后面跟着多行散文也不影响。
  out="$(printf '%s\n' \
    'API Error: 429' \
    'error_during_execution true I could not fix the failing test.' \
    'the mock raises it on purpose.' | "$SCRIPTS/classify-claude-failure.sh")"
  assert_equal "$(verdict "$out")" quota
}
