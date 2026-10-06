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
# 「同一条只推一次」盯的是模型本身，不是时间：推成功那一轮会留下一份以模型 id 命名的凭据
# （本 workflow 的 artifact，名字 opus-notified-<id>），下一轮先问「这份凭据在不在」。
# 发布时间一概不参与这个判断 —— 它是模型的发布时间，不是「这个令牌第一次看见它」的时间，
# 两者能差开；拿它当依据时，发布日期比上一次探测还早的新模型会被判成「推过了」，然后永远
# 不再提醒（MEL-294 审核退回的就是这个洞）。查不到凭据、凭据过期、凭据没留上，一律按
# 「没推过」算：宁可同一条重复推一次，也不许把新模型咽掉。
#
# 环境变量：
#   CLAUDE_CODE_OAUTH_TOKEN  读 /v1/models 用（已有密钥，和 Claude 修复共用，只读不烧额度）
#   REPO                     owner/repo，查凭据用（workflow 里是 github.repository）
#   GH_TOKEN                 查凭据用（Actions 自带令牌够，要 actions: read）
#   PUSHOVER_TOKEN / PUSHOVER_USER  两个都有才推
#   FORCE_NOTIFY             true = 推过也再推一次（手动跑时勾 force）
#   MODELS_JSON              测试 / 本地调试用：拿这个文件当 /v1/models 的响应，不联网
set -euo pipefail

REPO="${REPO:-}"
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
# 发布时间只拿来显示。没给、或者填的是 1970 年（接口说「不详」）都照样往下走：
# 「推过没有」问的是凭据，跟时间无关，所以这里没有任何需要时间才能做的判断。
case "$latest_at" in
  ''|1970-01-01T00:00:00*) latest_when="发布时间未知" ;;
  *) latest_when="$latest_at 发布" ;;
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

# ── 4. 不一样：这个模型推过了没有 ──
# 问的是「有没有一份以这个模型 id 命名的凭据」。名字里只留 artifact 认的那几类字符，
# 读和写用同一行换法，所以两边永远算出同一个名字。
ledger_name="opus-notified-$(printf '%s' "$latest_id" | tr -c 'A-Za-z0-9._-' '-')"
notified=false
if [ "$FORCE_NOTIFY" = true ]; then
  say "_手动跑勾了 force：推过也再推一次。_"
else
  : "${REPO:?REPO 没设，查不到这个模型推过没有}"
  # name= 是接口自带的精确过滤；jq 里再按名字比一次，万一接口忽略了这个参数，也不会把
  # 别的模型的凭据当成这一条的（那又会变成「把没推过的新模型当成推过了」）。
  # 过期的凭据不算：GitHub 到期回收，回收之后按没推过处理，最坏重复推一条。
  if ! hits="$(LEDGER_NAME="$ledger_name" gh api \
    "repos/$REPO/actions/artifacts?name=$ledger_name&per_page=100" \
    --jq '[(.artifacts // [])[]
           | select(.name == env.LEDGER_NAME and (.expired // false) == false)] | length')"; then
    echo "::warning::查不到凭据列表，按「没推过」处理（可能重复推一条，但不会漏掉新模型）"
    hits=0
  fi
  case "$hits" in
    ''|*[!0-9]*)
      echo "::warning::凭据列表的回答认不出（'$hits'），按「没推过」处理"
      hits=0 ;;
  esac
  [ "$hits" -eq 0 ] || notified=true
fi

if [ "$notified" = true ]; then
  say "### 🔇 这条已经推过了，没有再推"
  say ""
  say "\`$latest_id\` 之前推成功过（留着凭据 \`$ledger_name\`）。"
  echo "差异存在但这个模型推过了（凭据 $ledger_name），不重复推送。"
  exit 0
fi

# ── 5. 推一条 ──
echo "有新 Opus：$latest_id，$mismatched 钉的还是 $pinned_values，推送通知。"

if [ -z "${PUSHOVER_TOKEN:-}" ] || [ -z "${PUSHOVER_USER:-}" ]; then
  echo "::error::PUSHOVER_TOKEN / PUSHOVER_USER 没设，这条通知发不出去"
  exit 1
fi

message="最新的 Opus 是 $latest_name（$latest_id，$latest_when），仓库里钉的还是 $pinned_values。"
message="$message 想换就把 claude-codex-iterate.yml 和 codex-approved-merge.yml 的 claude_model 默认值改成新的，合了 PR 再移 v1 标签；不换就不用管，这条下周不会再推。"
if ! curl -sf -X POST https://api.pushover.net/1/messages.json \
  --form-string "token=$PUSHOVER_TOKEN" --form-string "user=$PUSHOVER_USER" \
  --form-string "title=🤖 有新的 Opus 了" \
  --form-string "message=$message" >/dev/null; then
  echo "::error::Pushover 发送失败；这一轮红着停下，没留凭据，下一轮会重试"
  exit 1
fi

# ── 6. 推成功了才留凭据 ──
# 脚本只把「凭据叫什么、哪个文件」交出去，真正留下它的是 workflow 里上传那一步。
# 顺序只能是先推后留：反过来会把「推过了」记在一轮没推成功的探测上，新模型就被咽掉了。
marker="${RUNNER_TEMP:-$tmp}/opus-notified.txt"
printf '%s\n' "$latest_id" >"$marker"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    printf 'notified_artifact=%s\n' "$ledger_name"
    printf 'notified_marker=%s\n' "$marker"
  } >>"$GITHUB_OUTPUT"
fi

# 推成功才写进 summary：先写「已推送」再推，推挂了那行就是假的。
say "### 📣 有新的 Opus，已推送通知"
say ""
say "还钉着旧值的文件：$mismatched"
say ""
say "下一轮认凭据 \`$ledger_name\`，认出来就不再推这一条。"
