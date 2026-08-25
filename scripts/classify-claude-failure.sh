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

# 只认 provider 真吐出来的报错结构，逐行按锚定的正则匹配，不做裸子串匹配。
# 终态字段里的 `.result` 是 Claude 自己写的一段自然语言总结，「集成测试打下游
# 返回 503 service unavailable，我修不好」这种句子里的字样必须判成 business：
# 散文里出现同样的词不算数，得是整行的额度哨兵、`API Error: <状态码>` 这样的
# 前缀、snake_case 的机器错误码，或 provider 的原话。
#
# 每项写成 `标签::正则`，取第一个 `::` 拆分（正则里不会出现 `::`）。
# 匹配走 nocasematch，所以字符类一律写全大小写，别依赖折叠。
QUOTA_PATTERNS=(
  # Claude Code 用完订阅额度时，整个 result 字段就是这一句（可带 |<重置时间戳>）。
  # 前面允许 `<subtype> <is_error> ` 这段调用方拼进来的前缀。
  'usage limit reached::^[[:space:]]*([a-zA-Z_]+[[:space:]]+(true|false)[[:space:]]+)?claude ai usage limit reached(\|[0-9]+)?[[:space:]]*$'
  # Anthropic API 的 HTTP 错误行，形如 `API Error: 429 {...}`。必须带 `API Error`
  # 前缀 —— 光有状态码不算，业务日志里到处是 503。
  'API Error with a provider status code::(^|[^a-zA-Z])API Error:?[[:space:]]+(401|429|503|529)([^0-9]|$)'
  # 错误体里的机器错误码：snake_case，两侧要词边界，`test_rate_limit_error`
  # 这种自己的测试名不算。
  'structured provider error code::(^|[^a-zA-Z_])(rate_limit_error|authentication_error|overloaded_error|insufficient_quota|invalid_api_key)([^a-zA-Z_]|$)'
  # 余额不足和令牌过期，用 provider 的原话，不拆成 `credit` / `expired` 这种词。
  'credit balance is too low::(^|[^a-zA-Z])your credit balance is too low'
  'OAuth token has expired::(^|[^a-zA-Z])OAuth token has expired'
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
