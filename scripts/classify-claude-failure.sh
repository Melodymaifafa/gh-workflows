#!/usr/bin/env bash
#
# 把 Claude 这一轮的失败分成两类，决定 auto 模式要不要换 Codex 上：
#
#   quota    额度耗尽 / 限流 / 认证失效 / 服务不可用 —— 换个 provider 有意义
#   business 测试挂、构建挂、改不动代码 —— 换谁都一样挂，必须让 job 红
#
#   classify-claude-failure.sh [文件]        # 不给文件就读 stdin
#
# 打印 class=... 和 reason=...；$GITHUB_OUTPUT 存在时同样追加一份。
#
# 判不准就算 business（fail closed）。两种误判的代价不对称：把额度失败判成
# business，无非是 job 红了、人来看一眼；把业务失败判成 quota，则是一个本该
# 红的 PR 悄悄换个模型再改一轮，把真问题埋进绿勾里。
#
# 喂进来的必须是「这次运行的终态字段」，不能是整份对话记录 —— 记录里原样带着
# Codex 的 review 正文（外部输入），照抄一句 "usage limit reached" 就能骗出一次
# 换人。调用方负责裁剪，见 claude-codex-iterate.yml 的 Decide the takeover。
set -euo pipefail

# 只认 provider 真吐出来的报错结构，而且必须是一整行的开头 —— 散文里出现同样的
# 字样一律不算。
#
# 为什么是「行首」：真正可信的额度证据是 runner 自己从 execution_file 的结构化
# 字段（api_error_status、被拒的 rate_limit_event）里读出来、单独写成一行的
# `API Error: <状态码>`，见 claude-codex-iterate.yml 的 Decide the takeover。
# 模型写的 `.result` 是一段自然语言总结，「那条挂掉的测试期望 API Error: 429」
# 这种句子里出现状态码、`overloaded_error` 这类错误码，都只是它在描述自己修的
# 代码，不是 provider 在报错。以前的正则只要求这些字样前面不是字母，一个空格
# 就满足，于是整句散文照样命中 —— 一次本该打红的业务失败被判成额度耗尽，换个
# 模型再改一轮，真问题埋进绿勾里。
#
# 调用方把终态字段拼成 `<subtype> <is_error> <result>` 一行，所以行首之后只多
# 允许这一段前缀；`.result` 整个就是 provider 的报错时仍然命中，夹在句子中间就
# 不命中。匹配走 nocasematch，所以字符类一律写全大小写，别依赖折叠。
LINE_HEAD='^[[:space:]]*([a-zA-Z_]+[[:space:]]+(true|false)[[:space:]]+)?'

# 每项写成 `标签::正则`，取第一个 `::` 拆分（正则里不会出现 `::`）。
QUOTA_PATTERNS=(
  # Claude Code 用完订阅额度时，整个 result 字段就是这一句（可带 |<重置时间戳>）。
  "usage limit reached::${LINE_HEAD}claude ai usage limit reached(\|[0-9]+)?[[:space:]]*\$"
  # Anthropic API 的 HTTP 错误行，形如 `API Error: 429 {...}`。必须带 `API Error`
  # 前缀 —— 光有状态码不算，业务日志里到处是 503。
  "API Error with a provider status code::${LINE_HEAD}API Error:?[[:space:]]+(401|429|503|529)([^0-9]|\$)"
  # 错误体里的机器错误码：snake_case，后面要词边界，`test_rate_limit_error`
  # 这种自己的测试名不算（它不在行首）。
  "structured provider error code::${LINE_HEAD}(rate_limit_error|authentication_error|overloaded_error|insufficient_quota|invalid_api_key)([^a-zA-Z_]|\$)"
  # 余额不足和令牌过期，用 provider 的原话，不拆成 `credit` / `expired` 这种词。
  "credit balance is too low::${LINE_HEAD}your credit balance is too low"
  "OAuth token has expired::${LINE_HEAD}OAuth token has expired"
)

source_file="${1:--}"
if [ "$source_file" = '-' ]; then
  text="$(cat)"
elif [ -r "$source_file" ]; then
  text="$(cat -- "$source_file")"
else
  text=''
fi

class=business
reason='no provider-side failure marker; treating this as a business failure'

if [ -z "${text//[[:space:]]/}" ]; then
  reason='Claude left no diagnosable output; treating this as a business failure'
else
  # 大小写不敏感交给 shell，别拿 tr 折叠：终态字段里有中文，多字节输入喂给
  # tr 会炸。
  shopt -s nocasematch
  while IFS= read -r line; do
    for entry in "${QUOTA_PATTERNS[@]}"; do
      label="${entry%%::*}"
      pattern="${entry#*::}"
      if [[ $line =~ $pattern ]]; then
        class=quota
        reason="provider-side failure marker: $label"
        break 2
      fi
    done
  done <<<"$text"
  shopt -u nocasematch
fi

{
  printf 'class=%s\n' "$class"
  printf 'reason=%s\n' "$reason"
} | tee -a "${GITHUB_OUTPUT:-/dev/null}"
