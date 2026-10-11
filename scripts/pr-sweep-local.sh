#!/usr/bin/env bash
# 在主人的 Mac 上跑 PR 巡检，pm2 每 5 分钟拉起一次（装法见 README「巡检」的「节奏」）。
# 合并环节不再开着 GitHub 的 runner 等 Codex（等的每一分钟都计费），👍 / 沉默 / 召唤冷却改由巡检盯；
# pr-sweeper.yml 的定时任务实际 2–7 小时才跑一次，太慢，所以主力放在本机。
# 密钥读 onboard.sh 用的那份文件；GH_TOKEN 用 CODEX_TRIGGER_TOKEN，跟 pr-sweeper.yml 一样。
set -euo pipefail

secrets="${GH_WORKFLOWS_SECRETS:-$HOME/.config/gh-workflows/secrets.env}"
[ -r "$secrets" ] || { echo "读不到 $secrets" >&2; exit 1; }
# shellcheck source=/dev/null
. "$secrets"
: "${CODEX_TRIGGER_TOKEN:?$secrets 里没有 CODEX_TRIGGER_TOKEN}"

# 只把巡检要用的几样交给它，文件里别的密钥不进它的环境。
export GH_TOKEN="$CODEX_TRIGGER_TOKEN"
export PUSHOVER_TOKEN="${PUSHOVER_TOKEN:-}" PUSHOVER_USER="${PUSHOVER_USER:-}"
export OWNER="${OWNER:-Melodymaifafa}" SWEEP_MODE="${SWEEP_MODE:-live}"
unset CODEX_TRIGGER_TOKEN CLAUDE_CODE_OAUTH_TOKEN LINEAR_API_KEY

echo "== $(date '+%F %T') =="
exec "$(cd "$(dirname "$0")" && pwd)/pr-sweep.sh"
