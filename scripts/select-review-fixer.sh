#!/usr/bin/env bash
#
# 决定这一轮由谁修 PR，以及失败后允不允许换人。
#
#   select-review-fixer.sh <auto|claude|codex>
#
# 打印两行 key=value 到 stdout；$GITHUB_OUTPUT 存在时同样追加一份，
# 于是 workflow 里 `steps.<id>.outputs.first` 直接可用。
#
# 非法值一律当场报错退出，不静默回落到默认值 —— 调用桩里把 codex 拼成 codx
# 时必须红在这一步，而不是安安静静按 auto 跑完一整轮，事后没人看得出来。
set -euo pipefail

value="${1-}"

case "$value" in
  # auto：Claude 先上，只有 provider 侧失败（额度/限流/认证/服务不可用）
  # 才换 Codex。业务失败换谁都一样挂，由 classify-claude-failure.sh 区分。
  auto) first=claude; fallback_allowed=true ;;
  # claude：现有行为，永不回退。
  claude) first=claude; fallback_allowed=false ;;
  # codex：跳过 Claude，整轮交给 Codex。
  codex) first=codex; fallback_allowed=false ;;
  *)
    # 工作流命令要走 stdout，GitHub 才会把它渲染成 annotation。
    echo "::error::invalid review_fixer '$value' (expected auto, claude or codex)"
    exit 1
    ;;
esac

{
  printf 'first=%s\n' "$first"
  printf 'fallback_allowed=%s\n' "$fallback_allowed"
} | tee -a "${GITHUB_OUTPUT:-/dev/null}"
