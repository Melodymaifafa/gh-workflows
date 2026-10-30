#!/usr/bin/env bash
# 在主人的 Mac 上常驻跑 PR 巡检：每轮跑完歇 5 分钟，pm2 只管让它活着（装法见 README「巡检」的「节奏」）。
# 合并环节不再开着 GitHub 的 runner 等 Codex（等的每一分钟都计费），👍 / 沉默 / 召唤冷却改由巡检盯；
# pr-sweeper.yml 的定时任务实际 2–7 小时才跑一次，太慢，所以主力放在本机。
# 不用 pm2 的 --cron-restart 拉起跑一轮就退出的进程：pm2 文档写明 cron 只重启还活着的进程，退出了就没人拉。
# 密钥读 onboard.sh 用的那份文件，每轮重读；GH_TOKEN 用 CODEX_TRIGGER_TOKEN，跟 pr-sweeper.yml 一样。
# 总开关跟 pr-sweeper.yml 是同一个：gh-workflows 的 Actions 变量 SWEEP_MODE，每轮都读，改成 off 两边都停；
# 读不到就这一轮不扫。密钥文件里的 SWEEP_MODE 只能把它往下调（live → dry / off）。
set -euo pipefail

secrets="${GH_WORKFLOWS_SECRETS:-$HOME/.config/gh-workflows/secrets.env}"
here="$(cd "$(dirname "$0")" && pwd)"
switch_alerted=

notify() {
  if [ -z "${PUSHOVER_TOKEN:-}" ] || [ -z "${PUSHOVER_USER:-}" ]; then return 0; fi
  curl -q -sf -X POST https://api.pushover.net/1/messages.json \
    --form-string "token=$PUSHOVER_TOKEN" --form-string "user=$PUSHOVER_USER" \
    --form-string "title=$1" --form-string "message=$2" >/dev/null || echo "Pushover 发送失败" >&2
}

# 每轮在子 shell 里跑，密钥和环境不留到下一轮。退出码 3 = 本机 gh 读不了总开关（已推过一次手机）。
sweep_once() (
  [ -r "$secrets" ] || { echo "读不到 $secrets" >&2; exit 1; }
  # shellcheck source=/dev/null
  . "$secrets"
  : "${CODEX_TRIGGER_TOKEN:?$secrets 里没有 CODEX_TRIGGER_TOKEN}"

  # 只把巡检要用的几样交给它，文件里别的密钥不进它的环境。
  export GH_TOKEN="$CODEX_TRIGGER_TOKEN"
  export PUSHOVER_TOKEN="${PUSHOVER_TOKEN:-}" PUSHOVER_USER="${PUSHOVER_USER:-}"
  export OWNER="${OWNER:-Melodymaifafa}"
  # 本机日志只有主人看得到：私有仓库也写真名和 PR 号，gh 报错照常输出（pr-sweeper.yml 不设，公开日志照旧打码）。
  export SWEEP_LOG_REAL_NAMES=1
  unset CODEX_TRIGGER_TOKEN CLAUDE_CODE_OAUTH_TOKEN LINEAR_API_KEY

  # 总开关用本机 gh 的登录读（主人的账号，gh auth login 那个）：fine-grained PAT 没有 Variables 权限，
  # 读不了 Actions 变量。登录失效会 401。
  if ! remote="$(env -u GH_TOKEN -u GITHUB_TOKEN gh api "repos/$OWNER/gh-workflows/actions/variables/SWEEP_MODE" --jq .value 2>&1)"; then
    case "$remote" in
      *"HTTP 404"*) remote=off ;;  # 没设 = off，跟 pr-sweeper.yml 一样
      *"HTTP 401"*|*"HTTP 403"*)
        echo "本机 gh 读不了总开关 SWEEP_MODE，这一轮不扫：$remote" >&2
        [ -n "$switch_alerted" ] ||
          notify "🤖 本机 PR 巡检停了" "本机 gh 读不了 gh-workflows 的 Actions 变量 SWEEP_MODE（巡检总开关），本机巡检不敢动手；在 Mac 上 gh auth login 重新登录就会自己恢复。"
        exit 3 ;;
      *) echo "读不到总开关 SWEEP_MODE，这一轮不扫：$remote" >&2; exit 1 ;;
    esac
  fi
  local_mode="${SWEEP_MODE:-live}"
  case "$remote" in
    live) mode="$local_mode" ;;
    dry) case "$local_mode" in off) mode=off ;; *) mode=dry ;; esac ;;
    *) mode=off ;;  # off 或不认识的值，跟 pr-sweeper.yml 一样按 off
  esac
  export SWEEP_MODE="$mode"

  exec "$here/pr-sweep.sh"
)

while :; do
  echo "== $(date '+%F %T') =="
  rc=0
  sweep_once || rc=$?
  case "$rc" in
    0) switch_alerted= ;;
    3) switch_alerted=1 ;;
    *) echo "这一轮失败（退出码 ${rc}），5 分钟后再试" >&2 ;;
  esac
  sleep 300
done
