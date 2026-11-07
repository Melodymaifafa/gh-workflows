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
self="$here/$(basename "$0")"
self_sum="$(cksum "$self")"
switch_alerted=

notify() {
  if [ -z "${PUSHOVER_TOKEN:-}" ] || [ -z "${PUSHOVER_USER:-}" ]; then return 0; fi
  curl -q -sf -X POST https://api.pushover.net/1/messages.json \
    --form-string "token=$PUSHOVER_TOKEN" --form-string "user=$PUSHOVER_USER" \
    --form-string "title=$1" --form-string "message=$2" >/dev/null || echo "Pushover 发送失败" >&2
}

# 每行前加「日期 时间 」。用 date，不用 printf %(…)T：Mac 自带的 bash 3.2 没有。最后一行没换行也照打。
stamp() {
  while IFS= read -r line || [ -n "$line" ]; do printf '%s %s\n' "$(date '+%F %T')" "$line"; done
}

# 本机仓库跟上 develop，修复合并后不用等人来拉（做法照 wecom-agent-bot 的 src/self-update.js）。只在 develop 上、
# 已跟踪文件没改动时才拉。未跟踪文件不算改动：pm2 或 runner 留的临时文件不该让更新永远卡住，真跟新提交冲突时拉取自己会失败。
# 卡住的拉取会卡死之后每一轮，所以不等密码，连接没速度 60 秒就放弃。在 sweep_once 外面跑，碰不到密钥。
update_checkout() {
  local repo branch dirty before out
  repo="$(git -C "$here" rev-parse --show-toplevel 2>/dev/null)" ||
    { echo "自更新：${here} 不是 git 仓库，跳过"; return 0; }
  branch="$(git -C "$repo" symbolic-ref --short -q HEAD)" || branch="（没有分支）"
  [ "$branch" = develop ] || { echo "自更新：本机仓库在 ${branch}，不在 develop，跳过"; return 0; }
  # 看不了也算有改动：拿不准就不拉。
  dirty="$(git -C "$repo" status --porcelain --untracked-files=no 2>&1)"
  [ -z "$dirty" ] || { echo "自更新：本机仓库有没提交的改动，跳过"; return 0; }
  before="$(git -C "$repo" rev-parse HEAD)"
  if ! out="$(GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1 GIT_HTTP_LOW_SPEED_TIME=60 \
    git -C "$repo" pull --ff-only origin develop 2>&1)"; then
    echo "自更新：git pull 失败，这一轮照跑：$(printf '%s' "$out" | tr -s '[:space:]' ' ')"
    return 0
  fi
  [ "$(git -C "$repo" rev-parse HEAD)" = "$before" ] ||
    echo "自更新：更新到了 $(git -C "$repo" rev-parse --short HEAD)"
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

# 错误日志（这个循环自己的和 pr-sweep.sh 的）每行带时间；标准输出照旧，每轮开头有 == 时间 == 那一行。
exec 2> >(stamp >&2)

while :; do
  echo "== $(date '+%F %T') =="
  update_checkout || true  # 更新出什么错，这一轮都照跑（|| 也让函数里的 set -e 不生效）
  # 跑着的循环是旧代码，自己变了（刚拉到的，或别人拉的）就退出 0，pm2 拉起新代码。pr-sweep.sh 每轮重新启动，不用退出。
  if [ "$(cksum "$self")" != "$self_sum" ]; then
    echo "自更新：$(basename "$self") 变了，退出让 pm2 拉起新代码"
    exit 0
  fi
  rc=0
  sweep_once || rc=$?
  case "$rc" in
    0) switch_alerted= ;;
    3) switch_alerted=1 ;;
    *) echo "这一轮失败（退出码 ${rc}），5 分钟后再试" >&2 ;;
  esac
  sleep 300
done
