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

# 判据分两段，因为喂进来的文本本身就分两段（见 claude-codex-iterate.yml 的
# Decide the takeover）：
#
#   1. 前导的裸行 —— runner 自己从 execution_file 的结构化字段读出来写的，形如
#      `API Error: 429`。字段（api_error_status、被拒的 rate_limit_event）是 SDK
#      写的，模型伪造不了，这是唯一可信的额度证据。
#   2. 从第一条带 `<subtype> <is_error> ` 前缀的行开始 —— 那是模型自己写的
#      `.result`。调用方只给它的第一行拼上前缀，第 2 行起是裸行，于是「某一行
#      恰好以额度报错的字样开头」在多行总结里是常态（markdown 小结、分条列举）。
#      散文一律不算额度证据。
#
# 所以光锚行首不够：`.result` 一换行，新起的那一行以 `API Error: 429` /
# `overloaded_error` 开头就照样命中 —— 一次本该打红的业务失败被判成额度耗尽，
# 换个模型再改一轮，真问题埋进绿勾里。
#
# 匹配走 nocasematch，所以字符类一律写全大小写，别依赖折叠。

# 调用方拼的那段前缀：`<subtype> <is_error> `。认出它就等于认出「这一行往后都是
# 模型写的字」。
CALLER_PREFIX='[a-zA-Z_]+[[:space:]]+(true|false)[[:space:]]+'
PROSE_STARTS="^[[:space:]]*${CALLER_PREFIX}"

# 每项写成 `标签::正则`，取第一个 `::` 拆分（正则里不会出现 `::`）。只拿来看前导
# 的裸行；散文命中这些一律不算。
STRUCTURED_PATTERNS=(
  # Anthropic API 的 HTTP 错误行，形如 `API Error: 429 {...}`。必须带 `API Error`
  # 前缀 —— 光有状态码不算，业务日志里到处是 503。
  "API Error with a provider status code::^[[:space:]]*API Error:?[[:space:]]+(401|429|500|503|529)([^0-9]|\$)"
  # 错误体里的机器错误码：snake_case，后面要词边界。
  "structured provider error code::^[[:space:]]*(rate_limit_error|authentication_error|overloaded_error|insufficient_quota|invalid_api_key)([^a-zA-Z_]|\$)"
  # 余额不足和令牌过期，用 provider 的原话，不拆成 `credit` / `expired` 这种词。
  "credit balance is too low::^[[:space:]]*your credit balance is too low"
  "OAuth token has expired::^[[:space:]]*OAuth token has expired"
)

# 唯一允许的散文形态：Claude Code 用完订阅额度时，整个 `.result` 就是这一句（可带
# |<重置时间戳>）。要求它独占整行。带前缀的那个变体（这一个终态对象的 `.result`
# 整个就是这一句）不管排第几个对象都算数 —— 模型描述自己在改的代码时，写不出
# 只由这一句独占、不多不少的一整行。
#
# 不带前缀的裸行变体只在 `$prose` 还是 false 时才算：它原本是留给 runner 自己
# 写的结构化裸行的，可一旦某个对象的 `.result` 跨行、后续裸行是模型接着写的
# 散文，模型完全可能在讲一次失败的测试时原样引用这句话（这个仓库自己的测试
# 夹具里就有一模一样的字符串）——那不是额度证据，照旧判 business。
USAGE_LIMIT_BARE_PATTERN="^[[:space:]]*claude ai usage limit reached(\|[0-9]+)?[[:space:]]*\$"
USAGE_LIMIT_PREFIXED_PATTERN="^[[:space:]]*${CALLER_PREFIX}claude ai usage limit reached(\|[0-9]+)?[[:space:]]*\$"
USAGE_LIMIT_LABEL='usage limit reached'

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
  prose=false
  while IFS= read -r line; do
    if [[ $line =~ $USAGE_LIMIT_PREFIXED_PATTERN ]] ||
      { [ "$prose" = false ] && [[ $line =~ $USAGE_LIMIT_BARE_PATTERN ]]; }; then
      class=quota
      reason="provider-side failure marker: $USAGE_LIMIT_LABEL"
      break
    fi
    # 前缀一出现，后面全是模型写的字，不再当结构化证据看。
    if [[ $line =~ $PROSE_STARTS ]]; then
      prose=true
      continue
    fi
    [ "$prose" = false ] || continue
    for entry in "${STRUCTURED_PATTERNS[@]}"; do
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
