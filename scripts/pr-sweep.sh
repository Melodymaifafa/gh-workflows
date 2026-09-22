#!/usr/bin/env bash
# PR 巡检：扫 owner 名下所有没归档的仓库，给卡住的 PR 补一脚。
# 由 .github/workflows/pr-sweeper.yml 定时跑（cron 写的每 15 分钟，GitHub 实际 2–7 小时才跑一次）；
# 本地也能跑（GH_TOKEN 用 owner 的 PAT）。
#
# 集成分支 = 仓库默认分支上合并调用桩的 base_branch（见 integration_base）。
# 每个 open、非草稿、同仓库、标题不带 [no-codex-merge]/[no-claude] 的 PR，按顺序只走第一条命中的规则：
#   0. 没人管            → 仓库没接共享自动化、或 PR 没打向集成分支：空闲 ≥ 60 分钟时告警一次（unwatched），停。
#   1. 有冲突            → 告警一次（conflict），停。
#   2. 这个 head 已停车  → 停（no-fix、round-cap、retry-exhausted、CI 红且 unstable）。
#   3. 额度还没恢复      → 停（这个 head 上最晚的 until 还没到）。
#   4. head 有审查意见   → 空闲 ≥ 60 分钟或额度已恢复时发 M5 让 iterate 再修，每个 head 最多算 2 次
#                          （M5 之后又撞额度的那次不算），但 M5 总数封顶 6 次；用完且空闲 ≥ 60 分钟就告警一次
#                          retry-exhausted，停。
#   5. 其余              → 没人碰过且空闲 ≥ 30 分钟、或空闲 ≥ 60 分钟时重新请求审查（M1 + 巡检标记）；
#                          每个 head 最多 3 次、间隔 ≥ 60 分钟；然后告警一次 stalled；然后 7 天内每天一次。
#
# 环境变量：
#   OWNER            仓库 owner（必填）
#   SWEEP_MODE       off | dry | live。dry 只把「会做什么」写进 $GITHUB_STEP_SUMMARY，不写任何东西。
#   ONLY_REPOS       只扫这些仓库（逗号或空格分隔，仓库名或 owner/名）
#   NOW_EPOCH        测试用：假的「现在」
#   PUSHOVER_TOKEN / PUSHOVER_USER  告警推送（都有才推）
#
#   LABEL_KEY        私有仓库日志标签的 HMAC 密钥（默认用 GH_TOKEN）
#   SWEEP_READ_TOKEN 只读调用桩用的令牌（Contents: Read-only），没设就用 GH_TOKEN
#
# 日志和 $GITHUB_STEP_SUMMARY 是公开的：私有仓库只写 repo-<HMAC 前 8 位>，不写名字、PR 号和 SHA，
# gh 的报错也吞掉。Pushover 是私人通道，照写真名。
set -euo pipefail

: "${OWNER:?OWNER 没设}"
MODE="${SWEEP_MODE:-off}"
case "$MODE" in
  off) echo "SWEEP_MODE=off，不扫。"; exit 0 ;;
  dry|live) ;;
  *) echo "::error::SWEEP_MODE 只能是 off/dry/live，收到 '$MODE'"; exit 2 ;;
esac

now="${NOW_EPOCH:-$(date +%s)}"
summary_file="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

max_kicks=3
max_daily_kicks=7
max_retries=2
# 撞额度的重试不计数，但总次数也要封顶，免得额度一直不够时无限重试。
max_total_retries=6

summary() { printf '%s\n' "$*" >>"$summary_file"; }

# 从 PR、评论、review 里算出这个 head 的全部状态，一行 TSV（字段不留空，tab 连着会被 read 吞掉）。
# 标记只认 github-actions[bot] 写的或 OWNER 写的；claude[bot]（NONE）写什么都不算。
# shellcheck disable=SC2016  # jq 程序，$ 是 jq 变量
facts_jq='
def ts: if . == null then 0 else sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 end;
def trusted: .user.login == "github-actions[bot]" or .author_association == "OWNER";
def has($s): (.body // "") | contains($s);
$pr[0] as $p | $cs[0] as $c | $rs[0] as $r | ($now | tonumber) as $now
| ($c | map(select(trusted))) as $tc
| ($r | map(select(trusted))) as $tr
| [$tc[] | .created_at as $at | (.body // "")
    | capture("<!-- pr-guard: alert head=" + $h + " reason=(?<r>[a-z-]+) until=(?<u>[0-9]+|-) -->")
    | . + {at: ($at | ts)}] as $alerts
| [$tc[] | select(has("<!-- codex-review-head: " + $h + " -->") and has("<!-- pr-sweeper: kick -->"))
    | .created_at | ts] | sort as $kicks
| [$r[] | select(.author_association == "OWNER" and has("<!-- fix-retry: head=" + $h + " review="))
    | .submitted_at | ts] | sort as $retries
| [$alerts[] | select(.r == "fix-quota") | .at] as $quota_at
# 某次 M5 之后、下一次 M5 之前又撞了 fix-quota，这次重试不算数。
| [range(0; $retries | length) as $i | $retries[$i] as $t | ($retries[$i + 1] // 1e18) as $next
    | select(any($quota_at[]; . > $t and . < $next) | not)] | length as $counted
| [$r[] | select(.commit_id == $h and (.user.login == $codex
      or (.author_association == "OWNER" and has("claude-review-findings: " + $h))))]
    | sort_by(.submitted_at) as $findings
| ($retries | last // 0) as $last_retry
| ([$alerts[] | select(.u != "-") | .u | tonumber] | max // 0) as $until
| ([$alerts[] | select(.r == "fix-quota" or .r == "auth" or .r == "fix-failed")] | sort_by(.at) | last | .r // "none") as $fix_reason
| ([$p.updated_at | ts] + [$c[] | .created_at | ts] + [$r[] | .submitted_at | ts] | max) as $last
| [ $now - $last,
    (if any($tc[]; has("<!-- codex-review-head: " + $h + " -->")
          or has("<!-- pr-guard: fallback head=" + $h + " ")
          or has("<!-- claude-review-clean: " + $h + " -->"))
        or any($tr[]; has("claude-review-findings: " + $h)) then 1 else 0 end),
    ($findings | length),
    ($findings | last | .id // 0),
    $counted,
    ($kicks | length),
    ($kicks | last // 0),
    ([$alerts[] | select(.r == "stalled") | .at] | min // 0),
    ([$alerts[] | .r] | unique | join(",") | if . == "" then "-" else . end),
    (if $until > $now then 1 else 0 end),
    (if $until > 0 and $until <= $now and $until > $last_retry then 1 else 0 end),
    $fix_reason,
    ($p.mergeable_state // "unknown"),
    (if $p.merged then 1 else 0 end),
    ($retries | length)
  ] | @tsv
'

# 公开日志里的仓库名：私有仓库换成 repo-<HMAC-SHA256(full_name) 前 8 位>。
# 用带密钥的 HMAC，不然别人拿猜的仓库名算一下就能对上。没有密钥就只写 repo-private。
repo_label() {
  [ "$2" = true ] || { printf '%s' "$1"; return 0; }
  local key="${LABEL_KEY:-${GH_TOKEN:-}}"
  [ -n "$key" ] || { printf 'repo-private'; return 0; }
  printf 'repo-%s' "$(printf '%s' "$1" | openssl dgst -sha256 -hmac "$key" | awk '{print $NF}' | cut -c1-8)"
}

# integration_base <owner/名>：打印这个仓库的集成分支，即默认分支上合并调用桩里的 base_branch。
# 返回 0 = 读到了；3 = 没接共享自动化（文件不存在，或是没有共享 uses: 行的内联副本）；
# 4 = 读不了（403 等任何非 404 错误），或 base_branch 不是正常的分支名。
# 本仓库的同名文件是定义本身，调用桩叫 self-codex-approved-merge.yml，所以两个都看。
integration_base() {
  local f out line b re='^[A-Za-z0-9._/-]{1,100}$'
  for f in codex-approved-merge.yml self-codex-approved-merge.yml; do
    if ! out="$(GH_TOKEN="${SWEEP_READ_TOKEN:-${GH_TOKEN:-}}" gh api -H 'Accept: application/vnd.github.raw+json' "repos/$1/contents/.github/workflows/$f")"; then
      [ "$(jq -r '.status // (if .message == "Not Found" then 404 else empty end)' <<<"$out" 2>/dev/null)" = 404 ] && continue
      return 4
    fi
    grep -Eq "^[[:space:]]*uses:[[:space:]]*['\"]?$OWNER/gh-workflows/\.github/workflows/codex-approved-merge\.yml@" <<<"$out" || continue
    line="$(grep -E '^[[:space:]]*base_branch:' <<<"$out" | head -n 1)"
    # 没写 base_branch = 可复用工作流的默认值。
    [ -n "$line" ] || { printf develop; return 0; }
    b="$(sed -E 's/^[[:space:]]*base_branch:[[:space:]]*//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//' <<<"$line")"
    case "$b" in \"*\"|\'*\') b="${b:1:${#b}-2}" ;; esac
    [[ "$b" =~ $re ]] || return 4
    case "$b" in *..*) return 4 ;; esac
    printf '%s' "$b"
    return 0
  done
  return 3
}

# 下面这些函数读 sweep_pr 设的 repo / n / H / alerts / url / who / hs。
# who / hs 是日志用的：公开仓库 "owner/名#N" 和 " (sha7)"，私有仓库只有标签、hs 为空。
post_comment() {
  gh api -X POST "repos/$repo/issues/$n/comments" -f "body=$1" --silent
}

# 动手前再看一眼：PR 还开着、head 还是 H，才写。
head_unchanged() {
  [ "$(gh api "repos/$repo/pulls/$n" --jq '.state + " " + .head.sha')" = "open $H" ] && return 0
  echo "$who: head 变了或 PR 关了，这轮不动。"
  return 1
}

# alert_once <reason> <until> <一句话>：(H, reason) 已有可信 M6 就什么也不做；否则先推送再留标记。
alert_once() {
  local reason="$1" until="$2" msg="$3"
  case ",$alerts," in *",$reason,"*) return 0 ;; esac
  if [ "$MODE" = dry ]; then summary "- would alert $who reason=$reason$hs"; return 0; fi
  head_unchanged || return 0
  if [ -n "${PUSHOVER_TOKEN:-}" ] && [ -n "${PUSHOVER_USER:-}" ]; then
    # 推送失败就不留标记，下一轮巡检重发，免得告警丢了还当作已发。
    curl -sf -X POST https://api.pushover.net/1/messages.json \
      --form-string "token=$PUSHOVER_TOKEN" --form-string "user=$PUSHOVER_USER" \
      --form-string "title=🤖 PR 巡检：$repo#$n" --form-string "message=$msg $url" >/dev/null 2>&1 ||
      { echo "::warning::$who Pushover 发送失败，下轮重试"; return 0; }
  fi
  post_comment "$msg"$'\n\n'"<!-- pr-guard: alert head=$H reason=$reason until=$until -->"
  summary "- alerted $who reason=$reason$hs"
}

kick() {
  if [ "$MODE" = dry ]; then summary "- would kick $who$hs $1"; return 0; fi
  head_unchanged || return 0
  post_comment "@codex review"$'\n\n'"<!-- codex-review-head: $H -->"$'\n'"<!-- pr-sweeper: kick -->"
  summary "- kicked $who$hs $1"
}

# retry_fix <review id> <上次失败原因>：M5，一条 COMMENT review，iterate 收到后重修同一批意见。
retry_fix() {
  local why
  case "$2" in
    fix-quota) why="额度用完，现已恢复" ;;
    auth) why="Claude 令牌失效" ;;
    fix-failed) why="修复出错" ;;
    *) why="一直没有结果" ;;
  esac
  if [ "$MODE" = dry ]; then summary "- would retry fix $who$hs review=$1"; return 0; fi
  head_unchanged || return 0
  gh api -X POST "repos/$repo/pulls/$n/reviews" -f event=COMMENT -f "commit_id=$H" \
    -f "body=🤖 巡检：上次自动修复没完成（$why），再修一次。"$'\n'"<!-- fix-retry: head=$H review=$1 -->" --silent
  summary "- retried fix $who$hs review=$1"
}

# sweep_pr <owner/名> <N> <private> <集成分支，没接共享自动化是 -> <watched 1/0>
sweep_pr() {
  repo="$1" n="$2" private="$3" base="$4" watched="$5"
  gh api "repos/$repo/pulls/$n" >"$tmp/pr.json"
  gh api --paginate --slurp "repos/$repo/issues/$n/comments?per_page=100" | jq 'add // []' >"$tmp/comments.json"
  gh api --paginate --slurp "repos/$repo/pulls/$n/reviews?per_page=100" | jq 'add // []' >"$tmp/reviews.json"
  H="$(jq -r .head.sha "$tmp/pr.json")"
  url="$(jq -r .html_url "$tmp/pr.json")"
  if [ "$private" = true ]; then who="$(repo_label "$repo" true)" hs=""; else who="$repo#$n" hs=" (${H:0:7})"; fi

  local facts idle referenced findings target retries kicks last_kick stalled_at until_active until_passed fix_reason state merged total_retries
  facts="$(jq -rn --slurpfile pr "$tmp/pr.json" --slurpfile cs "$tmp/comments.json" --slurpfile rs "$tmp/reviews.json" \
    --arg h "$H" --arg now "$now" --arg codex 'chatgpt-codex-connector[bot]' "$facts_jq")"
  IFS=$'\t' read -r idle referenced findings target retries kicks last_kick stalled_at alerts \
    until_active until_passed fix_reason state merged total_retries <<<"$facts"
  echo "$who$hs: idle=${idle}s state=$state findings=$findings retries=$retries kicks=$kicks alerts=$alerts"

  # 0. 没人管：不叫审、不重修，告警一次。空闲 60 分钟再告，给人留时间改 base 或关掉。
  if [ "$watched" = 0 ]; then
    [ "$idle" -ge 3600 ] || { echo "  没人管，还不够空闲"; return 0; }
    if [ "$base" = - ]; then
      alert_once unwatched - "🤖 巡检：这个仓库没接共享的审查自动化，这个 PR 不会有人自动审或合。请接上共享调用桩，或手动处理。"
    else
      alert_once unwatched - "🤖 巡检：自动审查和合并只管打向 $base 的 PR，这个 PR 不会有人管。请把 base 改成 $base，或关掉。"
    fi
    return 0
  fi

  # 1. 冲突：只有人能解。
  if [ "$state" = dirty ]; then
    alert_once conflict - "🤖 巡检：这个 PR 和 $base 有冲突，自动流程停了；请在本地解决冲突后推上来。"
    return 0
  fi

  # 2. 已停车：等人处理，巡检不插手。
  case ",$alerts," in *,no-fix,*|*,round-cap,*|*,retry-exhausted,*) echo "  已停车"; return 0 ;; esac
  case ",$alerts," in *,ci,*) [ "$state" != unstable ] || { echo "  CI 红，已停车"; return 0; } ;; esac

  # 3. 额度还没恢复（取这个 head 上最晚的 until）。
  [ "$until_active" = 0 ] || { echo "  等额度恢复"; return 0; }

  # 4. 有意见：重修，不重审。
  if [ "$findings" -gt 0 ]; then
    [ "$idle" -ge 3600 ] || [ "$until_passed" = 1 ] || { echo "  修复可能还在跑"; return 0; }
    if [ "$retries" -lt "$max_retries" ] && [ "$total_retries" -lt "$max_total_retries" ]; then
      retry_fix "$target" "$fix_reason"
    elif [ "$idle" -ge 3600 ] && [ "$retries" -ge "$max_retries" ]; then
      alert_once retry-exhausted - "🤖 自动修复重试 2 次还是没完成，已停。你来点 Merge 或关掉；推新提交会重新开始。"
    elif [ "$idle" -ge 3600 ]; then
      alert_once retry-exhausted - "🤖 自动修复试了 6 次都卡在 Claude 额度上，已停。你来点 Merge 或关掉；推新提交会重新开始。"
    else
      echo "  最后一次重修可能还在跑"
    fi
    return 0
  fi

  # 5. 没意见也没合：重新请求审查。
  [ "$merged" = 0 ] || return 0
  if ! { [ "$referenced" = 0 ] && [ "$idle" -ge 1800 ]; } && [ "$idle" -lt 3600 ]; then
    echo "  还不够空闲"; return 0
  fi
  local since_kick=$((now - last_kick))
  if [ "$kicks" -lt "$max_kicks" ]; then
    [ "$since_kick" -lt 3600 ] || kick "($((kicks + 1))/$max_kicks)"
  elif [ "$stalled_at" = 0 ]; then
    [ "$since_kick" -lt 3600 ] ||
      alert_once stalled - "🤖 巡检：请求审查 $max_kicks 次都没有结果，请打开 PR 看看卡在哪；之后每天自动再请求一次，共 7 天。"
  elif [ "$now" -lt $((stalled_at + 7 * 86400)) ] && [ "$since_kick" -ge 86400 ] &&
    [ $((now - stalled_at)) -ge 86400 ] &&
    [ "$kicks" -lt $((max_kicks + max_daily_kicks)) ]; then
    kick "(每日)"
  fi
}

# ── 仓库：owner 名下、没归档（默认分支不限） ──
# shellcheck disable=SC2016
repos="$(gh api --paginate --slurp "user/repos?affiliation=owner&per_page=100" |
  jq -r --arg o "$OWNER" --arg only "${ONLY_REPOS:-}" '
    [$only | splits("[, ]+") | select(. != "")] as $only
    | add // [] | .[]
    | select(.owner.login == $o and (.archived | not))
    | select(($only | length) == 0 or (.name as $n | .full_name as $f | any($only[]; . == $n or . == $f)))
    | "\(.full_name):\(.private == true):\(.default_branch)"')"

summary "### PR 巡检（$MODE）"
failed=0 unreadable=0 unreadable_labels=""
for entry in $repos; do
  # 仓库名和分支名都不含 : 和空白。
  repo="${entry%%:*}" rest="${entry#*:}"
  private="${rest%%:*}" default_branch="${rest#*:}"
  label="$(repo_label "$repo" "$private")"
  # 私有仓库的 gh 报错里有仓库名，吞掉，只留一句通用警告。
  err=/dev/stderr
  [ "$private" = false ] || err=/dev/null
  if ! prs="$(gh api --paginate "repos/$repo/pulls?state=open&per_page=100" --jq '
      .[] | select(.draft | not)
      | select(.head.repo.full_name == .base.repo.full_name)
      | select((.title | contains("[no-codex-merge]") or contains("[no-claude]")) | not)
      | "\(.number):\(.base.ref)"' 2>"$err")"; then
    echo "::warning::$label 列 PR 失败"; failed=1; continue
  fi
  # 没有要管的 PR 就不读调用桩。
  [ -n "$prs" ] || continue

  legacy=0
  if base="$(integration_base "$repo" 2>"$err")"; then
    :
  else
    case $? in
      3) base=- ;;
      *)
        # 读不到调用桩（多半是令牌没有 Contents 读权限）：退回旧规则，
        # 只管默认分支是 develop 的仓库里合进 develop 的 PR，别的一概不碰（也不告 unwatched）。
        unreadable=$((unreadable + 1)) unreadable_labels="$unreadable_labels $label"
        [ "$default_branch" = develop ] || continue
        base=develop legacy=1 ;;
    esac
  fi
  # 私有仓库的分支名也是私密的，只给公开仓库打。
  if [ "$private" = false ]; then
    if [ "$base" = - ]; then echo "$repo: 没接共享审查自动化"; else echo "$repo: 集成分支 $base"; fi
  fi

  for p in $prs; do
    n="${p%%:*}" pr_base="${p#*:}" watched=1
    if [ "$base" = - ] || [ "$pr_base" != "$base" ]; then
      [ "$legacy" = 0 ] || continue
      watched=0
    fi
    # 一个 PR 出错不拖累其它 PR；子 shell 里重开 -e（|| 语境下 -e 会失效，所以不用 ||）。
    set +e
    (set -e; sweep_pr "$repo" "$n" "$private" "$base" "$watched") 2>"$err"
    rc=$?
    set -e
    if [ "$private" = true ]; then pr_label="$label"; else pr_label="$repo#$n"; fi
    [ "$rc" = 0 ] || { echo "::warning::$pr_label 巡检出错（exit $rc）"; failed=1; }
  done
done
if [ "$unreadable" -gt 0 ]; then
  echo "::warning::$unreadable 个仓库读不到合并调用桩，按旧规则只扫默认分支是 develop 的（多半是没设 SWEEP_READ_TOKEN，或它缺 Contents: Read-only）：${unreadable_labels# }"
fi
exit "$failed"
