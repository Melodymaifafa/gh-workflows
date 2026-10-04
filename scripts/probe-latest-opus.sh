#!/usr/bin/env bash
# 探「现在最新的 Opus 是哪个」，跟本仓库钉死的 claude_model 默认值比，不一样就推一条 Pushover。
# 由 .github/workflows/opus-model-probe.yml 每周跑一次；本地也能跑（见下面的环境变量）。
# 只提醒，不改默认值 —— 改默认 = 改一行 + 合 PR + 移 v1 标签，那一步在人手里。
#
# 为什么问接口而不是问别名 `opus`：别名跟的是 Claude Code 的版本，不是模型发布。
# 2026-10-04 在 Claude Code 2.1.266 上实测 `claude -p --model opus --output-format json`，
# 回报 model=claude-opus-5，而 /v1/models 当天最新的 Opus 是 claude-opus-5-5（2026-09-21 发布）。
# 别名落后整整一代，而且问它要烧一次真实推理；接口是只读的，带发布时间，一次 HTTP 就够。
#
# 「同一个结论只推一次」不存状态，靠水位：本 workflow 上一次**成功**的 run 的开始时间。
# 只有「最新那个 Opus 的发布时间」晚于这个水位才推 —— 新模型出现的那一周推一条，之后安静；
# 她一直没改默认值也不会每周重复。推送失败时这一轮是红的，水位不前进，下一轮会重试。
# 例外：接口没给发布时间（填的是 1970 年）的模型没法跟水位比，只能每轮都推，直到默认值换了。
#
# 环境变量：
#   CLAUDE_CODE_OAUTH_TOKEN  读 /v1/models 用（已有密钥，和 Claude 修复共用，只读不烧额度）
#   REPO                     owner/repo，查自己 run 历史用（workflow 里是 github.repository）
#   GH_TOKEN                 查 run 历史用（Actions 自带令牌够）
#   WORKFLOW_FILE            本 workflow 的文件名，默认 opus-model-probe.yml
#   PUSHOVER_TOKEN / PUSHOVER_USER  两个都有才推
#   FORCE_NOTIFY             true = 无视水位，差了就推（手动跑时勾 force）
#   MODELS_JSON              测试 / 本地调试用：拿这个文件当 /v1/models 的响应，不联网
#   NOTIFY_WATERMARK         测试 / 本地调试用：假的水位（ISO 8601），不问 GitHub
set -euo pipefail

REPO="${REPO:-}"
WORKFLOW_FILE="${WORKFLOW_FILE:-opus-model-probe.yml}"
FORCE_NOTIFY="${FORCE_NOTIFY:-false}"
summary_file="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
tmp="$(mktemp -d)"

say() { printf '%s\n' "$*" >>"$summary_file"; }

# ── 1. 最新的 Opus ──
models="${MODELS_JSON:-$tmp/models.json}"
if [ -z "${MODELS_JSON:-}" ]; then
  : "${CLAUDE_CODE_OAUTH_TOKEN:?CLAUDE_CODE_OAUTH_TOKEN 没设，查不了模型列表}"
  # 令牌走 -H @文件 而不是命令行参数：命令行在 ps 里是人人可见的。
  {
    printf 'Authorization: Bearer %s\n' "$CLAUDE_CODE_OAUTH_TOKEN"
    printf 'anthropic-beta: oauth-2025-04-20\n'
    printf 'anthropic-version: 2023-06-01\n'
  } >"$tmp/headers"
  if ! curl -sS --fail-with-body -o "$models" -H @"$tmp/headers" \
    "https://api.anthropic.com/v1/models?limit=100"; then
    echo "::error::取模型列表失败（/v1/models），这一轮不做判断、不推送"
    exit 1
  fi
fi

# 只看 claude-opus-*：钉死的那两个默认值就是 Opus，别的家族（fable / mythos）不在这张票里。
# 取列表里第一个：接口文档写明按发布时间新→旧排。不自己按 created_at 排 —— 发布时间不详时
# 接口会填 1970 年（文档允许），自己排的话偏偏这种新模型会排到所有旧的后面，永远挑不中。
latest_json="$(
  jq -c '
    [(.data // [])[] | select((.id // "") | startswith("claude-opus-"))] | .[0] // empty
  ' "$models" 2>/dev/null || true
)"
if [ -z "$latest_json" ]; then
  echo "::error::模型列表里没有一个 claude-opus-*（响应不对或权限不够），这一轮不做判断、不推送"
  exit 1
fi

latest_id="$(jq -r '.id' <<<"$latest_json")"
latest_name="$(jq -r '.display_name // .id' <<<"$latest_json")"
latest_at="$(jq -r '.created_at // ""' <<<"$latest_json")"
if [ -z "$latest_at" ]; then
  echo "::error::$latest_id 没有 created_at，判断不了新旧，这一轮不推送"
  exit 1
fi
# 1970 年 = 接口说「发布时间不详」：显示成未知，第 4 步也不拿它比水位。
case "$latest_at" in
  1970-01-01T00:00:00*) released_known=false; latest_when="发布时间未知" ;;
  *) released_known=true; latest_when="$latest_at 发布" ;;
esac

# ── 2. 仓库里钉死的默认值 ──
# 读的是真文件，不维护第二份清单：这两个 workflow 的 claude_model 默认值就是「现在钉的」。
pinned_default() { # pinned_default <workflow 文件>
  awk '
    $0 == "      claude_model:"            { in_block = 1; next }
    in_block && index($0, "        default: ") == 1 { sub(/^        default: /, ""); print; exit }
    in_block && $0 ~ /^      [A-Za-z_]/    { exit }
  ' "$1"
}

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
pinned_list=""     # 写进 summary：哪个文件钉的是什么
pinned_values=""   # 写进通知：钉的那些值（去重）
mismatched=""      # 和最新的不一样的那些文件
for f in claude-codex-iterate.yml codex-approved-merge.yml; do
  value="$(pinned_default "$repo_root/.github/workflows/$f")"
  if [ -z "$value" ]; then
    echo "::error::$f 里读不到 claude_model 的默认值（格式变了？），这一轮不推送"
    exit 1
  fi
  pinned_list="${pinned_list:+$pinned_list，}\`$f\` 钉 \`$value\`"
  case " $pinned_values " in
    *" $value "*) ;;
    *) pinned_values="${pinned_values:+$pinned_values / }$value" ;;
  esac
  [ "$value" = "$latest_id" ] || mismatched="${mismatched:+$mismatched }$f"
done

# ── 3. 一样就什么都不发 ──
say "最新的 Opus：**$latest_name**（\`$latest_id\`，$latest_when）"
say ""
say "仓库钉的：$pinned_list"
say ""
if [ -z "$mismatched" ]; then
  say "### ✅ 已经是最新的，没有推送"
  echo "钉的就是最新的 Opus（$latest_id），不推送。"
  exit 0
fi

# ── 4. 不一样：这个结论推过了没有 ──
watermark=""   # 留空 = 不比水位，直接推
if [ "$FORCE_NOTIFY" = true ]; then
  say "_手动跑勾了 force：无视「推过没有」，直接推。_"
elif [ "$released_known" != true ]; then
  # 拿 1970 年去比，它永远「早于上一次成功探测」，新模型就被咽掉了。
  # 不存状态就没别的办法分辨推没推过：宁可每轮都推，也不漏。
  say "_接口没给 \`$latest_id\` 的发布时间，判断不了推没推过：照推，下一轮可能还会再推。_"
elif [ -n "${NOTIFY_WATERMARK:-}" ]; then
  watermark="$NOTIFY_WATERMARK"
else
  : "${REPO:?REPO 没设，查不到自己的 run 历史}"
  # 读不到就当「没推过」：这样最坏是同一条重复推一次，而不是把新模型咽掉。
  # （第一次跑、workflow 刚进默认分支时这个接口会 404，正是「当没推过」该生效的场景。）
  if ! watermark="$(gh api \
    "repos/$REPO/actions/workflows/$WORKFLOW_FILE/runs?status=success&per_page=1" \
    --jq '.workflow_runs[0].run_started_at // "1970-01-01T00:00:00Z"')"; then
    echo "::warning::读不到本 workflow 上一次成功的 run，按「没推过」处理（可能重复推一条，但不会漏）"
    watermark="1970-01-01T00:00:00Z"
  fi
fi

epoch() { jq -rn --arg s "$1" '$s | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601'; }
if [ -n "$watermark" ]; then
  if ! latest_epoch="$(epoch "$latest_at")" || ! watermark_epoch="$(epoch "$watermark")"; then
    echo "::error::时间格式认不出（模型 '$latest_at'，水位 '$watermark'），这一轮不推送"
    exit 1
  fi

  if [ "$latest_epoch" -le "$watermark_epoch" ]; then
    say "### 🔇 这条已经推过了，没有再推"
    say ""
    say "\`$latest_id\` 在上一次成功探测（$watermark）之前就发布了。"
    echo "差异存在但已经推过（模型 $latest_at ≤ 水位 $watermark），不重复推送。"
    exit 0
  fi
fi

# ── 5. 推一条 ──
echo "有新 Opus：$latest_id，$mismatched 钉的还是 $pinned_values，推送通知。"

if [ -z "${PUSHOVER_TOKEN:-}" ] || [ -z "${PUSHOVER_USER:-}" ]; then
  echo "::error::PUSHOVER_TOKEN / PUSHOVER_USER 没设，这条通知发不出去"
  exit 1
fi

message="最新的 Opus 是 $latest_name（$latest_id，$latest_when），仓库里钉的还是 $pinned_values。"
message="$message 想换就把 claude-codex-iterate.yml 和 codex-approved-merge.yml 的 claude_model 默认值改成新的，合了 PR 再移 v1 标签；"
if [ "$released_known" = true ]; then
  message="${message}不换就不用管，这条下周不会再推。"
else
  message="${message}接口没给它的发布时间，分不清推没推过，所以没换之前下周可能还会再推。"
fi
if ! curl -sf -X POST https://api.pushover.net/1/messages.json \
  --form-string "token=$PUSHOVER_TOKEN" --form-string "user=$PUSHOVER_USER" \
  --form-string "title=🤖 有新的 Opus 了" \
  --form-string "message=$message" >/dev/null; then
  echo "::error::Pushover 发送失败；这一轮红着停下，水位不前进，下一轮会重试"
  exit 1
fi

# 推成功才写进 summary：先写「已推送」再推，推挂了那行就是假的。
say "### 📣 有新的 Opus，已推送通知"
say ""
say "还钉着旧值的文件：$mismatched"
