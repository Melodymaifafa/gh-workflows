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

# 只认 provider 侧的具体报错串。别加 "error" / "failed" 这种通用词：它们在
# 业务失败里同样满地都是，加进来等于把 fail-closed 拆了。
QUOTA_MARKERS=(
  'usage limit reached'
  'rate limit'
  'rate_limit_error'
  'error 429'
  'status 429'
  'insufficient_quota'
  'quota exceeded'
  'credit balance is too low'
  'authentication_error'
  'invalid api key'
  'invalid_api_key'
  'invalid_request_error: invalid bearer token'
  'oauth token has expired'
  'token expired'
  '401 unauthorized'
  'error 401'
  'status 401'
  'overloaded_error'
  'error 529'
  'status 529'
  'service unavailable'
  'error 503'
  'status 503'
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
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  for marker in "${QUOTA_MARKERS[@]}"; do
    case "$lower" in
      *"$marker"*)
        class=quota
        reason="provider-side failure marker: $marker"
        break
        ;;
    esac
  done
fi

{
  printf 'class=%s\n' "$class"
  printf 'reason=%s\n' "$reason"
} | tee -a "${GITHUB_OUTPUT:-/dev/null}"
