#!/usr/bin/env bash
# PR 巡检：扫 owner 名下所有没归档的仓库，给卡住的 PR 补一脚。
# 主人的 Mac 上每 5 分钟跑一次（scripts/pr-sweep-local.sh，pm2 管）；.github/workflows/pr-sweeper.yml
# 的定时任务兜底（cron 写的每 15 分钟，GitHub 实际 2–7 小时才跑一次）。
#
# 集成分支 = 仓库默认分支上合并调用桩的 base_branch（见 integration_base）。
# 每个 open、非草稿、同仓库、标题不带 [no-codex-merge]/[no-claude]、分支不是 agent/* 的 PR，按顺序只走第一条命中的规则：
# （agent/* 是 momo 的分支：momo 在 Mac 上自己追 Codex、自己合并，两边一起动会互相撞推送。）
#   0. 没人管            → 仓库没接共享自动化、或 PR 没打向集成分支：空闲 ≥ 60 分钟时告警一次（unwatched），停。
#   1. 有冲突            → 留一条不推手机的 conflict 标记叫醒合并工作流，由它把集成分支合进来、停；
#                          它解不了会自己告警（conflict-stuck）；留言后空闲 ≥ 2 小时还没动静就由巡检告警。
#   2. 这个 head 已停车  → 停（no-fix、round-cap、retry-exhausted、merge-refused、carried-open、CI 红且 unstable）。
#   3. 额度还没恢复      → 停（这个 head 上最晚的 until 还没到）。
#   4. head 有审查意见   → 空闲 ≥ 60 分钟或额度已恢复时发 M5 让 iterate 再修，每个 head 最多算 2 次
#                          （M5 之后又撞额度的那次不算），但 M5 总数封顶 6 次；用完且空闲 ≥ 60 分钟就告警一次
#                          retry-exhausted，停。修满轮数后 Claude 判过可合（M8）点名的 review 不算意见。
#   4b. 有 M8 还没合     → 多半是当时 CI 还没绿：空闲 ≥ 60 分钟就把同一个 M8 再发一次，让合并检查重跑；
#                          每个 head 最多补 2 次，之后告警一次 stalled，停。
#   6. 替合并工作流盯 Codex（它不再开着 runner 等，等的每一分钟都计费）：
#      a. 修复那轮推了 head（有 M7）还没召唤 → 离上一条 review 满 6 分钟就召唤（M1，带 fix-round）。
#      b. 最近一次召唤之后 Codex 点了 👍    → 留 codex-thumbs 标记叫醒合并检查（路径 F），每次召唤一条；
#                                             没合上（多半是当时 CI 还没绿）就空闲 ≥ 60 分钟再留一条，
#                                             最多补 2 次，之后告警一次 stalled。
#      d. Codex 审查摘要显示 H 审完、没意见 → 审完满 2 分钟就留 codex-summary 标记叫醒合并检查（路径 H），补叫同 b。
#                                             打开 PR 时的自动审查审完没意见只改这条摘要，不发 clean 评论、不点 👍。
#                                             H 上已有 Codex 的 clean 评论（它自己叫醒过路径 C）就算叫过一次。不再重审。
#      c. Codex 没接这次召唤                → 额度用完马上、5 分钟没任何回应、或 20 分钟 head 上没结论（审它的 clean 评论 / review）时，
#                                             留 codex-silent 标记让合并检查换 Claude 代审（路径 G），每次召唤一条。
#      e. 摘要显示 Codex 正在审 H           → 等它，不重审；20 分钟还在审就当卡住，交给规则 5。
#                                             代码审查审完、安全审查还在审 H 也算正在审。
#      带 M7 的 head（本流水线自己推的）上被 GitHub 扣住等批准的 CI，顺手批掉。
#   5. 其余              → 没人碰过且空闲 ≥ 10 分钟、或空闲 ≥ 60 分钟时重新请求审查（M1 + 巡检标记）；
#                          每个 head 最多 3 次、间隔 ≥ 60 分钟；然后告警一次 stalled；然后 7 天内每天一次。
#
# Codex 额度（全局，所有仓库共用一个 ChatGPT 账号）：任何 PR 上 Codex 回了「额度用完」就记下来，
# 到「再试」的时间之前，6a 的召唤和规则 5 的 kick 都不喊 @codex review，直接请 Claude 审（同一条
# 评论带上召唤的标记和 codex-silent，合并检查走路径 G）。Codex 的回复里没有恢复时间，所以到点只
# 试一次：又撞上就隔更久（1 / 2 / 4 / 8 小时），Codex 正常审完一次就清掉。状态记在 $OWNER/gh-workflows
# 一条主人开的 issue 里（最后一行标记），iterate 和合并工作流召唤前也读它。读不到就按「额度正常」算。
# 每轮先把所有 PR 读一遍、额度证据收齐，再逐个动手，所以喊不喊 Codex 跟先扫哪个 PR 无关；动手前
# 再读一遍那个 PR，按它眼下的样子动手。本机和 Actions 的巡检可能同时在跑，写回 issue 前也再读一次，
# 别的巡检这期间写过就在它写的上面重算。
#
# 环境变量：
#   OWNER            仓库 owner（必填）
#   SWEEP_MODE       off | dry | live。dry 只把「会做什么」写进 $GITHUB_STEP_SUMMARY，不写任何东西。
#   ONLY_REPOS       只扫这些仓库（逗号或空格分隔，仓库名或 owner/名）
#   NOW_EPOCH        测试用：假的「现在」
#   PUSHOVER_TOKEN / PUSHOVER_USER  告警推送（都有才推）
#
#   LABEL_KEY        私有仓库日志标签的 HMAC 密钥（默认用 GH_TOKEN）
#   SWEEP_LOG_REAL_NAMES  1 = 日志里私有仓库也写真名（pr-sweep-local.sh 设，见 hidden）
#
# 读调用桩也用 GH_TOKEN（CODEX_TRIGGER_TOKEN，带 Contents 权限）；以前那把单独的
# SWEEP_READ_TOKEN 不再读 —— 留着一把过期的反而会顶掉能用的那把。
#
# 日志和 $GITHUB_STEP_SUMMARY 是公开的：私有仓库只写 repo-<HMAC 前 8 位>，不写名字、PR 号和 SHA，
# gh 的报错也吞掉。Pushover 是私人通道，照写真名；主人 Mac 上的日志也是（见 hidden）。
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
# M8 之后合并检查最多补跑 2 次（加上 judge 自己发的那条，一共 3 条 M8）；👍 叫醒的也一样（一共 3 条 codex-thumbs）。
max_merge_rekicks=2
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
# Codex clean 评论审的是不是 H：同合并检查的路径 C，取第一行 **Reviewed commit:** `前缀`，H 以它开头才算。
def reviewed_h: [(.body // "") | split("\n")[] | capture("^\\*\\*Reviewed commit:\\*\\* `(?<c>[0-9a-f]{7,40})`").c]
    | (first // "") as $pre | $pre != "" and ($h | startswith($pre));
# Codex 审查摘要：Codex 在 PR 上开、之后原地改的那条评论，第二行 codex-review-state:v1 后面是机器读的状态。
# 只认 Codex 本人（登录名 + Bot 类型）：OWNER / github-actions 贴一份同样的文字不算（同 M8，Codex 2026-10-04 的 P1）。
# 读不出状态就当没有。合并检查的路径 H（codex_summary_clean）是同一套判据，改这里要一起改。
def summary_state: select(.user.login == $codex and .user.type == "Bot" and has("<!-- codex-pull-request-review-summary -->"))
    | [(.body // "") | capture("<!-- codex-review-state:v1 (?<s>\\{.*\\}) -->").s | try fromjson catch empty] | first // empty;
def sha_on_h: (.commit_sha // "") as $s | ($s | length) >= 7 and ($h | startswith($s));
def summary_on_h: .code_review | sha_on_h;
# 审完 H 没意见：同 Codex 点 👍 的条件，跑过的审查（代码审查，和有的话安全审查）都审完了、都没意见。
def summary_clean: .code_review.status == "completed" and summary_on_h
    and all((.code_review, .security_review) | select(type == "object" and .status != null);
      .status == "completed" and .has_any_findings == false);
# 正在审 H：H 上有一项审查（代码审查或安全审查）开了还没审完。代码审查审完、安全审查还在跑也算，
# 不然会落到「其他」，空闲够了就再喊一遍 @codex review（Codex 2026-10-19 的 P2）。
def summary_running: any((.code_review, .security_review) | select(type == "object");
    .status != null and .status != "completed" and sha_on_h);
$pr[0] as $p | $cs[0] as $c | $rs[0] as $r | ($now | tonumber) as $now
| ($c | map(select(trusted))) as $tc
| ($r | map(select(trusted))) as $tr
| [$tc[] | .created_at as $at | (.body // "")
    | capture("<!-- pr-guard: alert head=" + $h + " reason=(?<r>[a-z-]+) until=(?<u>[0-9]+|-) -->")
    | . + {at: ($at | ts)}] as $alerts
| [$tc[] | select(has("<!-- codex-review-head: " + $h + " -->") and has("<!-- pr-sweeper: kick -->"))
    | .created_at | ts] | sort as $kicks
# 这个 head 上最近一次可信召唤（iterate 或巡检发的 M1、巡检 kick；都带 codex-review-head: H）。
| ([$tc[] | select(has("<!-- codex-review-head: " + $h + " -->")) | {id, at: (.created_at | ts)}]
    | max_by(.at) // {id: 0, at: 0}) as $summon
| [$r[] | select(.author_association == "OWNER" and has("<!-- fix-retry: head=" + $h + " review="))
    | .submitted_at | ts] | sort as $retries
| [$alerts[] | select(.r == "fix-quota") | .at] as $quota_at
# 某次 M5 之后、下一次 M5 之前又撞了 fix-quota，这次重试不算数。
| [range(0; $retries | length) as $i | $retries[$i] as $t | ($retries[$i + 1] // 1e18) as $next
    | select(any($quota_at[]; . > $t and . < $next) | not)] | length as $counted
# M8：修满轮数后 Claude 判定这几条 review 不拦合并（claude-codex-iterate 的 round-cap-judge）。
# 只认主人写的，同 codex-approved-merge 的路径 E：github-actions[bot] 的评论里可能转贴着 Claude
# 写的文字，认了它，巡检就会拿主人的 PAT 把一个没人判过的标记再发一遍（Codex 2026-10-04 的 P1）。
| [$c[] | select(.author_association == "OWNER") | (.body // "")
    | capture("<!-- claude-judge-clean: head=" + $h + " reviews=(?<ids>[0-9]+(,[0-9]+)*) -->")] as $m8
| ([$m8[] | .ids | split(",")[] | tonumber] | unique) as $judged
| [$r[] | select(.commit_id == $h and (.id as $id | any($judged[]; . == $id) | not) and (.user.login == $codex
      or (.author_association == "OWNER" and has("claude-review-findings: " + $h))))]
    | sort_by(.submitted_at) as $findings
| ($retries | last // 0) as $last_retry
| ([$alerts[] | select(.u != "-") | .u | tonumber] | max // 0) as $until
| ([$alerts[] | select(.r == "fix-quota" or .r == "auth" or .r == "fix-failed")] | sort_by(.at) | last | .r // "none") as $fix_reason
| ([$p.updated_at | ts] + [$c[] | .created_at | ts] + [$r[] | .submitted_at | ts] | max) as $last
# 摘要按最后一次改的时间算（审完 / 开审的时间）。
| ([$c[] | {id, at: (.updated_at // .created_at | ts), st: summary_state}] | max_by(.at)) as $sum
| ($sum | if . == null then "none" elif (.st | summary_clean) then "clean"
    elif (.st | summary_running) then "running"
    else "other" end) as $sum_status
| [ $now - $last,
    (if any($tc[]; has("<!-- codex-review-head: " + $h + " -->")
          or has("<!-- pr-guard: fallback head=" + $h + " ")
          or has("<!-- pr-guard: codex-silent head=" + $h + " ")
          or has("<!-- claude-review-clean: " + $h + " -->")
          or has("<!-- claude-judge-clean: head=" + $h + " "))
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
    ($retries | length),
    ($m8 | length),
    ($m8 | last | .ids // "-"),
    $summon.id,
    $summon.at,
    ([$tc[] | (.body // "") | capture("<!-- pr-guard: fix-round head=" + $h + " round=(?<n>[0-9]+) -->").n | tonumber] | max // 0),
    ([$r[] | .submitted_at | ts] | max // 0),
    ([$c[] | select(.user.login == $codex and (.created_at | ts) >= $summon.at)] | length),
    (if any($c[]; .user.login == $codex and (.created_at | ts) >= $summon.at and has("reached your Codex usage limits")) then 1 else 0 end),
    ([$r[] | select(.user.login == $codex and (.submitted_at | ts) >= $summon.at)] | length),
    (if any($tc[]; (.created_at | ts) >= $summon.at
          and (has("<!-- pr-guard: fallback head=" + $h + " ") or has("<!-- pr-guard: codex-silent head=" + $h + " "))) then 1 else 0 end),
    ([$tc[] | select((.created_at | ts) >= $summon.at and has("<!-- pr-guard: codex-thumbs head=" + $h + " "))] | length),
    # 召唤之后 Codex 在 H 上的结论：审 H 的 review，或审的是 H 的 clean 评论。上一个 head 的审查晚于
    # 这次召唤才到也常见，那只算有动静（召唤之后的评论数、review 数），不算结论（Codex 2026-10-11 的 P2）。
    ([$r[] | select(.user.login == $codex and .commit_id == $h and (.submitted_at | ts) >= $summon.at)]
      + [$c[] | select(.user.login == $codex and (.created_at | ts) >= $summon.at and has("find any major issues") and reviewed_h)]
      | length),
    # 全局额度状态的证据（不分 head）：Codex 最近一次回「额度用完」，和最近一次正常审完（review 或 clean 评论）。
    ([$c[] | select(.user.login == $codex and has("reached your Codex usage limits")) | .created_at | ts] | max // 0),
    ([$r[] | select(.user.login == $codex) | .submitted_at | ts]
      + [$c[] | select(.user.login == $codex and has("find any major issues")) | .created_at | ts] | max // 0),
    ($sum.id // 0),
    $sum_status,
    ($sum.at // 0),
    ([$tc[] | select(has("<!-- pr-guard: codex-summary head=" + $h + " "))] | length),
    # H 上有 Codex 的 clean 评论：那条评论自己叫醒过合并检查的路径 C。
    (if any($c[]; .user.login == $codex and has("find any major issues") and reviewed_h) then 1 else 0 end)
  ] | @tsv
'

# hidden <private>：日志里要不要藏起这个仓库。私有仓库藏，除非在主人 Mac 上跑：那份日志只有主人
# 看得到，pr-sweep-local.sh 设 SWEEP_LOG_REAL_NAMES=1，照写真名、PR 号、SHA 和 gh 的报错。
# Actions 的 run 日志是公开的，那里设了也不认。
hidden() { [ "$1" = true ] && { [ "${SWEEP_LOG_REAL_NAMES:-}" != 1 ] || [ "${GITHUB_ACTIONS:-}" = true ]; }; }

# 公开日志里的仓库名：私有仓库换成 repo-<HMAC-SHA256(full_name) 前 8 位>。
# 用带密钥的 HMAC，不然别人拿猜的仓库名算一下就能对上。没有密钥就只写 repo-private。
repo_label() {
  hidden "$2" || { printf '%s' "$1"; return 0; }
  local key="${LABEL_KEY:-${GH_TOKEN:-}}"
  [ -n "$key" ] || { printf 'repo-private'; return 0; }
  printf 'repo-%s' "$(printf '%s' "$1" | openssl dgst -sha256 -hmac "$key" | awk '{print $NF}' | cut -c1-8)"
}

# integration_base <owner/名>：打印这个仓库的集成分支，即默认分支上合并调用桩里的 base_branch。
# 返回 0 = 读到了；3 = 没接共享自动化（文件不存在，或是没有共享 uses: 行的内联副本）；
# 4 = 读不了（403 等任何非 404 错误），或 base_branch 不是正常的分支名。
# 本仓库的同名文件是定义本身，调用桩叫 self-codex-approved-merge.yml，所以两个都看。
# 首字符不许是 - . /：否则 `-` 会和主循环里「没接入」的占位值撞上。
integration_base() {
  local f out line b re='^[A-Za-z0-9_][A-Za-z0-9._/-]{0,99}$'
  for f in codex-approved-merge.yml self-codex-approved-merge.yml; do
    if ! out="$(gh api -H 'Accept: application/vnd.github.raw+json' "repos/$1/contents/.github/workflows/$f")"; then
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
    case "$b" in *..*|*//*|*/.*|*/|*.) return 4 ;; esac
    printf '%s' "$b"
    return 0
  done
  return 3
}

# ── Codex 额度（全局）──
# $quota_file 一行：issue 号（0 = 还没建）、最后一次撞上的时间、再试的时间、连续撞上几次。
# collect_pr / sweep_pr 跑在子 shell 里，所以状态放文件，不放变量。
quota_repo="$OWNER/gh-workflows"
quota_file="$tmp/codex-quota"
quota_known=1
# shellcheck disable=SC2016  # jq 程序
quota_jq='[.[] | select((.pull_request | not) and .user.login == $o)
    | {n: .number, m: ((.body // "") | capture("<!-- codex-quota-state: hit=(?<h>[0-9]+) until=(?<u>[0-9]+) strikes=(?<s>[0-9]+) -->"))}]
  | first | if . == null then "0 0 0 0" else "\(.n) \(.m.h) \(.m.u) \(.m.s)" end'

# read_quota_issue <文件>：issue 里记的状态写成一行进文件；读不到返回 1。
# 只认主人开的 issue：仓库是 public，谁都能开一条带同样标记的 issue。
read_quota_issue() {
  local issues
  issues="$(gh api "repos/$quota_repo/issues?state=open&creator=$OWNER&per_page=100" 2>/dev/null)" &&
    jq -r --arg o "$OWNER" "$quota_jq" <<<"$issues" >"$1" 2>/dev/null
}

load_quota() {
  if read_quota_issue "$quota_file"; then
    :
  else
    quota_known=0
    echo "0 0 0 0" >"$quota_file"
    echo "::warning::读不到 Codex 额度状态（${quota_repo} 的 issue），这一轮按「额度正常」算，也不写回"
  fi
  cp "$quota_file" "$tmp/codex-quota.loaded"
  # 这一轮各 PR 上看到的：最晚一次撞上、最晚一次正常审完。
  echo "0 0" >"$tmp/codex-quota.seen"
}

quota_backoff() { case "$1" in 1) echo 3600 ;; 2) echo 7200 ;; 3) echo 14400 ;; *) echo 28800 ;; esac; }

# beijing <epoch>：北京时间 MM-DD HH:MM（macOS 的 date 没有 -d，用 jq）。
beijing() { jq -nr --argjson t "$(($1 + 28800))" '$t | strftime("%m-%d %H:%M")'; }

# note_quota <最近一次「额度用完」的时间> <最近一次 Codex 正常审完的时间>：把一个 PR 上看到的证据并进这一轮的证据，
# 再从读进来的状态重算全局状态。只看这一轮最晚的那次撞上和最晚的那次审完，结果跟先扫哪个 PR 无关 ——
# 不然先扫到的 PR 上的「审完」清了状态，后扫到的 PR 上更早的「额度用完」又会被当成新撞上（Codex 2026-10-16 的 P2）。
note_quota() {
  local q="$1" ok="$2" qi qh qu qs sq sok
  read -r sq sok <"$tmp/codex-quota.seen"
  [ "$q" -le "$sq" ] || sq="$q"
  [ "$ok" -le "$sok" ] || sok="$ok"
  echo "$sq $sok" >"$tmp/codex-quota.seen"
  read -r qi qh qu qs <"$tmp/codex-quota.loaded"
  if [ "$sq" -gt "$qh" ]; then
    if [ "$sok" -gt "$qh" ]; then
      # 上次撞上之后 Codex 正常审完过：额度回来过，这次撞上从头算。
      qs=0 qu=0
    elif [ $((sq - qh)) -gt 86400 ]; then
      # 上次撞上已经是一天多以前：新的一段，从头算。
      qs=0
    fi
    # 到了再试的时间还撞上 = 试过一次没恢复，下次隔更久。没到时间的那些（打开 PR 时 Codex 自己去审、
    # 回的「额度用完」）只更新最后一次撞上的时间。
    if [ "$sq" -ge "$qu" ]; then
      qs=$((qs + 1))
      qu=$((sq + $(quota_backoff "$qs")))
    fi
    qh="$sq"
  fi
  # 最晚的一件事是 Codex 正常审完：额度回来了。
  if [ "$sok" -gt "$qh" ] && [ "$qs" -gt 0 ]; then qs=0 qu=0; fi
  echo "$qi $qh $qu $qs" >"$quota_file"
}

codex_out() {
  local qi qh qu qs
  read -r qi qh qu qs <"$quota_file"
  [ "$now" -lt "$qu" ]
}

# save_quota：状态变了才写回 issue（没有就开一条）。dry 只写进 run 摘要；读不到状态时不写，免得开出第二条。
save_quota() {
  cmp -s "$quota_file" "$tmp/codex-quota.loaded" && return 0
  local qi qh qu qs state body
  # 本机每 5 分钟的巡检和 Actions 的定时巡检可能同时在跑：写之前再读一次 issue。这期间别的巡检写过，
  # 就把这一轮看到的证据在它写的状态上重算一遍，免得拿开头读到的旧状态盖掉它记下的撞上、加长的等待
  # 或清零，也免得两边各开一条 issue（Codex 2026-10-16 的 P2）。
  if [ "$MODE" = live ] && [ "$quota_known" = 1 ]; then
    read_quota_issue "$tmp/codex-quota.latest" ||
      { echo "::warning::写回前读不到 Codex 额度状态（${quota_repo} 的 issue），这一轮不写"; return 0; }
    if ! cmp -s "$tmp/codex-quota.latest" "$tmp/codex-quota.loaded"; then
      cp "$tmp/codex-quota.latest" "$tmp/codex-quota.loaded"
      note_quota 0 0
      cmp -s "$quota_file" "$tmp/codex-quota.loaded" && return 0
    fi
  fi
  read -r qi qh qu qs <"$quota_file"
  if [ "$now" -lt "$qu" ]; then
    state="Codex 审查额度用完了。北京时间 $(beijing "$qu") 之后再试 Codex；在那之前，所有审查直接交给 Claude。"
  elif [ "$qs" -gt 0 ]; then
    state="Codex 审查额度到了再试的时间，下一次审查先试 Codex。"
  else
    state="Codex 审查额度正常。"
  fi
  summary "- Codex 额度：${state}"
  [ "$MODE" = live ] && [ "$quota_known" = 1 ] || return 0
  body="${state}"$'\n\n'"这条 issue 由 PR 巡检（scripts/pr-sweep.sh）自动维护：Codex 回「额度用完」就记下，到点再试一次，试通了就清掉。别关，也别改最后那行。"$'\n\n'"<!-- codex-quota-state: hit=$qh until=$qu strikes=$qs -->"
  if [ "$qi" = 0 ]; then
    # 还没有 issue、Codex 眼下也没被拦着（比如只看到一条早就过了再试时间的旧回复）：不值得开一条。
    [ "$now" -lt "$qu" ] || return 0
    gh api -X POST "repos/$quota_repo/issues" -f "title=Codex 审查额度（PR 巡检维护）" -f "body=$body" --silent ||
      echo "::warning::Codex 额度状态写不进 ${quota_repo}（开 issue 失败）"
  else
    gh api -X PATCH "repos/$quota_repo/issues/$qi" -f "body=$body" --silent ||
      echo "::warning::Codex 额度状态写不进 ${quota_repo}（改 issue 失败）"
  fi
}

# 下面这些函数读 sweep_pr 设的 repo / n / H / alerts / url / who / hs，和主循环设的 dir（这个 PR 的数据目录）。
# who / hs 是日志用的：公开仓库 "owner/名#N" 和 " (sha7)"，藏起来的私有仓库（hidden）只有标签、hs 为空。
post_comment() {
  gh api -X POST "repos/$repo/issues/$n/comments" -f "body=$1" --silent
}

# 动手前再看一眼：PR 还开着、head 还是 H，才写。
head_unchanged() {
  [ "$(gh api "repos/$repo/pulls/$n" --jq '.state + " " + .head.sha')" = "open $H" ] && return 0
  echo "$who: head 变了或 PR 关了，这轮不动。"
  return 1
}

# alert_once <reason> <until> <一句话> [quiet]：(H, reason) 已有可信 M6 就什么也不做；否则先推送再留标记。
# quiet：只留标记不推手机（标记本身就是给别的工作流看的，人还不用管）。
alert_once() {
  local reason="$1" until="$2" msg="$3"
  case ",$alerts," in *",$reason,"*) return 0 ;; esac
  if [ "$MODE" = dry ]; then summary "- would alert $who reason=$reason$hs"; return 0; fi
  head_unchanged || return 0
  if [ "${4:-}" != quiet ] && [ -n "${PUSHOVER_TOKEN:-}" ] && [ -n "${PUSHOVER_USER:-}" ]; then
    # 推送失败就不留标记，下一轮巡检重发，免得告警丢了还当作已发。
    curl -q -sf -X POST https://api.pushover.net/1/messages.json \
      --form-string "token=$PUSHOVER_TOKEN" --form-string "user=$PUSHOVER_USER" \
      --form-string "title=🤖 PR 巡检：$repo#$n" --form-string "message=$msg $url" >/dev/null 2>&1 ||
      { echo "::warning::$who Pushover 发送失败，下轮重试"; return 0; }
  fi
  post_comment "$msg"$'\n\n'"<!-- pr-guard: alert head=$H reason=$reason until=$until -->"
  summary "- alerted $who reason=$reason$hs"
}

kick() {
  if codex_out; then hand_to_claude quota "<!-- codex-review-head: $H -->" "<!-- pr-sweeper: kick -->"; return 0; fi
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
    -f "body=🤖 巡检：上次自动修复没完成（${why}），再修一次。"$'\n'"<!-- fix-retry: head=$H review=$1 -->" --silent
  summary "- retried fix $who$hs review=$1"
}

# rekick_merge <review ids>：把 Claude 判过可合的那条 M8 原样再发一次（只换开头那句话），
# codex-approved-merge 的路径 E 会重新跑一遍：CI 绿了就合，H 上有没点名的新意见照样拦。
rekick_merge() {
  if [ "$MODE" = dry ]; then summary "- would re-request the merge check $who$hs"; return 0; fi
  head_unchanged || return 0
  post_comment "🤖 巡检：Claude 已判定剩下的意见不拦合并，但还没合上（多半是当时 CI 还没绿），再请合并检查跑一次。"$'\n\n'"<!-- claude-judge-clean: head=$H reviews=$1 -->"
  summary "- re-requested the merge check $who$hs"
}

# summon_fix_round <round>：修复那一轮推上去的 head，冷却过了再召唤 Codex。正文跟 iterate 自己发的 M1
# 一字不差（fix-round 是轮数计数器），不带 pr-sweeper: kick，不算巡检的 kick 次数。
summon_fix_round() {
  if [ "$MODE" = dry ]; then summary "- would summon Codex for fix round $1 $who$hs"; return 0; fi
  head_unchanged || return 0
  post_comment "@codex review"$'\n\n'"<!-- codex-review-head: $H -->"$'\n'"<!-- fix-round: $1 -->"
  summary "- summoned Codex for fix round $1 $who$hs"
}

# wake_merge <Codex 怎么表示的> <标记> <这个信号已叫醒过几次>：Codex 审过没意见，但没有叫得醒合并检查的事件
# （👍 没有 reaction 事件；审查摘要是原地改的评论，调用桩只接新评论）。留路径 F / H 的标记叫醒它，信号由它再核。
# 叫醒的那次没合上（CI 红了又在同一个 head 上重跑绿了、当时还没跑完、一时合不了）：调用桩不接 CI 跑完的事件，
# 同一个 head 上再没有什么会叫醒合并检查。所以同 4b，空闲 60 分钟再叫，最多补 2 次，之后告警一次 stalled。
# CI 还红着的那种在规则 2 就停车了，到不了这里。
wake_merge() {
  local how="$1" marker="$2" times="$3" msg
  if [ "$times" = 0 ]; then
    msg="🤖 巡检：Codex 审过没意见（${how}），请合并检查跑一次。"
  elif [ "$idle" -lt 3600 ]; then
    echo "  等合并检查"; return 0
  elif [ "$times" -le "$max_merge_rekicks" ]; then
    msg="🤖 巡检：Codex 审过没意见（${how}），但还没合上（多半是当时 CI 还没绿），再请合并检查跑一次。"
  else
    alert_once stalled - "🤖 巡检：Codex 审过没意见（${how}），但合并检查跑了 $times 次都没合上，请打开 PR 看看卡在哪。"
    return 0
  fi
  if [ "$MODE" = dry ]; then summary "- would wake the merge check $who$hs"; return 0; fi
  head_unchanged || return 0
  post_comment "$msg"$'\n\n'"$marker"
  summary "- woke the merge check $who$hs"
}

# hand_to_claude <quota|silent|timeout> [标记行…]：留路径 G 的标记，合并检查换 Claude 代审。合并检查
# 不再另发一条「换 Claude」，PR 上就这一句。Codex 额度还没恢复时，召唤和 kick 也走这里，多带的
# 标记行（codex-review-head 加 fix-round 或 kick）让这条评论同时算这个 head 的一次审查请求。
hand_to_claude() {
  local reason="$1" msg body line qi qh qu qs
  shift
  case "$reason" in
    quota)
      read -r qi qh qu qs <"$quota_file"
      msg="🤖 Codex 审查额度用完了，这次请 Claude 审。"
      [ "$now" -ge "$qu" ] || msg+="北京时间 $(beijing "$qu") 之后再试 Codex。"
      ;;
    silent) msg="🤖 Codex 5 分钟没回应，这次请 Claude 审。" ;;
    *) msg="🤖 Codex 20 分钟没出结论，这次请 Claude 审。" ;;
  esac
  if [ "$MODE" = dry ]; then summary "- would hand $who$hs to Claude ($reason)"; return 0; fi
  head_unchanged || return 0
  body="$msg"$'\n'
  for line in "$@" "<!-- pr-guard: codex-silent head=$H reason=$reason -->"; do body+=$'\n'"$line"; done
  post_comment "$body"
  summary "- handed $who$hs to Claude ($reason)"
}

# approve_held_runs：GitHub 把本流水线推的提交上的 CI 扣成 action_required、等人点批准时（MEL-292），
# 用主人的令牌批掉。只对带 M7 的 head 调用：别人推的提交一概不批。
approve_held_runs() {
  local ids id
  ids="$(gh api "repos/$repo/actions/runs?head_sha=$H&per_page=100" \
    --jq ".workflow_runs[] | select(.head_sha == \"$H\" and .conclusion == \"action_required\") | .id")" ||
    { echo "  列不出这个 head 上的 run（令牌要有 Actions: Read and write）"; return 0; }
  for id in $ids; do
    if [ "$MODE" = dry ]; then summary "- would approve a held run $who$hs"; continue; fi
    if gh api -X POST "repos/$repo/actions/runs/$id/approve" --silent; then
      summary "- approved a held run $who$hs"
    else
      echo "::warning::$who 批不了被扣住的 CI（令牌要有 Actions: Read and write）"
    fi
  done
}

# fetch_reactions：PR 正文和最近那条召唤上的 reaction 存进 $dir；读不到返回 1。
fetch_reactions() {
  gh api --paginate --slurp "repos/$repo/issues/$n/reactions?per_page=100" >"$dir/pr-reactions.raw" || return 1
  gh api --paginate --slurp "repos/$repo/issues/comments/$summon_id/reactions?per_page=100" >"$dir/summon-reactions.raw" || return 1
  jq 'add // []' "$dir/pr-reactions.raw" >"$dir/pr-reactions.json" || return 1
  jq 'add // []' "$dir/summon-reactions.raw" >"$dir/summon-reactions.json" || return 1
}

# codex_reaction <content> <since epoch>：Codex 在 PR 正文或最近那条召唤上、since 之后有没有这个 reaction（1/0）。
codex_reaction() {
  jq -n --slurpfile a "$dir/pr-reactions.json" --slurpfile b "$dir/summon-reactions.json" \
    --arg content "$1" --arg since "$2" --arg codex 'chatgpt-codex-connector[bot]' '
    def ts: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    if any(($a[0] + $b[0])[]; .content == $content and .user.login == $codex and (.created_at | ts) >= ($since | tonumber))
    then 1 else 0 end'
}

# read_facts：$dir/facts 那一行读进调用者的变量（sweep_pr 里是 local）。
read_facts() {
  IFS=$'\t' read -r idle referenced findings target retries kicks last_kick stalled_at alerts \
    until_active until_passed fix_reason state merged total_retries judged judged_reviews \
    summon_id summon_at m7_round last_review_at codex_comments codex_quota codex_reviews handed woken codex_concluded \
    quota_seen codex_ok_seen summary_id summary_status summary_at summary_woken receipt_h <"$dir/facts"
}

# fetch_pr <owner/名> <N>：读 PR、评论、review 存进 $dir，算好事实行；召唤过就连 Codex 的 👍 / 👀 一起读，
# 读不到就不留 reactions 文件（上一次读的也删掉）。
fetch_pr() {
  repo="$1" n="$2"
  rm -f "$dir/reactions"
  gh api "repos/$repo/pulls/$n" >"$dir/pr.json"
  gh api --paginate --slurp "repos/$repo/issues/$n/comments?per_page=100" | jq 'add // []' >"$dir/comments.json"
  gh api --paginate --slurp "repos/$repo/pulls/$n/reviews?per_page=100" | jq 'add // []' >"$dir/reviews.json"
  H="$(jq -r .head.sha "$dir/pr.json")"
  jq -rn --slurpfile pr "$dir/pr.json" --slurpfile cs "$dir/comments.json" --slurpfile rs "$dir/reviews.json" \
    --arg h "$H" --arg now "$now" --arg codex 'chatgpt-codex-connector[bot]' "$facts_jq" >"$dir/facts"
  read_facts
  if [ "$summon_at" -gt 0 ] && fetch_reactions; then
    thumbs="$(codex_reaction +1 "$summon_at")"
    eyes="$(codex_reaction eyes "$summon_at")"
    echo "$thumbs $eyes" >"$dir/reactions"
  fi
}

# collect_pr <owner/名> <N>：第一遍。fetch_pr，再把这个 PR 上的额度证据并进这一轮。主循环先对所有 PR
# 跑完这个才 sweep_pr：额度是全局的，不能先扫到的 PR 已经喊了 @codex review，后面 PR 上那条「额度用完」
# 才读到 —— 那样发出去的请求取决于 PR 的先后（Codex 2026-10-16 的 P2）。
collect_pr() {
  fetch_pr "$1" "$2"
  note_quota "$quota_seen" "$codex_ok_seen"
  # 👍 也算 Codex 正常审完了一次（额度回来了）。
  if [ -f "$dir/reactions" ] && [ "$thumbs" != 0 ]; then note_quota 0 "$summon_at"; fi
}

# sweep_pr <owner/名> <N> <private> <集成分支，没接共享自动化是 -> <watched 1/0>：按 fetch_pr 存在 $dir 里的动手。
sweep_pr() {
  repo="$1" n="$2" private="$3" base="$4" watched="$5"
  H="$(jq -r .head.sha "$dir/pr.json")"
  url="$(jq -r .html_url "$dir/pr.json")"
  if hidden "$private"; then who="$(repo_label "$repo" true)" hs=""; else who="$repo#$n" hs=" (${H:0:7})"; fi

  local idle referenced findings target retries kicks last_kick stalled_at until_active until_passed fix_reason state merged total_retries judged judged_reviews
  local summon_id summon_at m7_round last_review_at codex_comments codex_quota codex_reviews handed woken codex_concluded thumbs eyes
  local quota_seen codex_ok_seen summary_id summary_status summary_at summary_woken receipt_h
  read_facts
  echo "$who$hs: idle=${idle}s state=$state findings=$findings retries=$retries kicks=$kicks alerts=$alerts"

  # 0. 没人管：不叫审、不重修，告警一次。空闲 60 分钟再告，给人留时间改 base 或关掉。
  if [ "$watched" = 0 ]; then
    [ "$idle" -ge 3600 ] || { echo "  没人管，还不够空闲"; return 0; }
    if [ "$base" = - ]; then
      alert_once unwatched - "🤖 巡检：这个仓库没接共享的审查自动化，这个 PR 不会有人自动审或合。在 gh-workflows 里跑 ./onboard.sh ${repo#*/} <python|node> 接上，或手动处理。"
    else
      alert_once unwatched - "🤖 巡检：自动审查和合并只管打向 $base 的 PR，这个 PR 不会有人管。请把 base 改成 ${base}，或关掉。"
    fi
    return 0
  fi

  # 1. 冲突：这条留言（主人 PAT 发的）叫醒合并工作流的 resolve-conflict，由它把 $base 合进来。
  #    冲突的 PR 上 pull_request 类事件都不触发，issue_comment 照样触发，所以靠留言叫。
  #    合好了 head 就变了；解不了它自己告警 conflict-stuck。留言后 2 小时还没动静，说明它没跑起来。
  if [ "$state" = dirty ]; then
    case ",$alerts," in
      *,conflict-stuck,*) echo "  冲突已交给人" ;;
      *,conflict,*)
        if [ "$idle" -ge 7200 ]; then
          alert_once conflict-stuck - "🤖 巡检：这个 PR 和 ${base} 有冲突，自动解冲突 2 小时都没结果。请在本地把 ${base} 合进来、解完冲突后推上来。"
        else
          echo "  等自动解冲突"
        fi
        ;;
      *) alert_once conflict - "🤖 巡检：这个 PR 和 ${base} 有冲突，合并工作流会先自动把 ${base} 合进来；解不了会再通知你。" quiet ;;
    esac
    return 0
  fi

  # 2. 已停车：等人处理，巡检不插手。
  # carried-open：审查通过了，但更早的意见还开着，合并检查拦着等人 —— 它已经在这个 head 上补过
  # 一条请修复的 review、修过一轮还没关掉，或者没有主人的 PAT 补不了。再叫审只会再拿一个「通过」、
  # 再被拦一次。
  case ",$alerts," in *,no-fix,*|*,round-cap,*|*,retry-exhausted,*|*,merge-refused,*|*,carried-open,*) echo "  已停车"; return 0 ;; esac
  case ",$alerts," in *,ci,*) [ "$state" != unstable ] || { echo "  CI 红，已停车"; return 0; } ;; esac

  # 3. 额度还没恢复（取这个 head 上最晚的 until）。
  [ "$until_active" = 0 ] || { echo "  等额度恢复"; return 0; }

  # 本流水线推的 head 上被扣住的 CI：不批就一直不跑，合并检查等不到 CI。
  if [ "$m7_round" -gt 0 ] && [ "$merged" = 0 ]; then approve_held_runs; fi

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

  [ "$merged" = 0 ] || return 0

  # 4b. Claude 判过可合（M8）还没合上：再请合并检查跑一次，不重审 —— 重审出来的同一批意见
  #     是新 review，M8 没点它的名，反而会把这个 head 拦死。
  if [ "$judged" -gt 0 ]; then
    [ "$idle" -ge 3600 ] || { echo "  等合并检查"; return 0; }
    if [ "$judged" -le "$max_merge_rekicks" ]; then
      rekick_merge "$judged_reviews"
    else
      alert_once stalled - "🤖 巡检：Claude 判定剩下的意见不拦合并，但合并检查跑了 $judged 次都没合上，请打开 PR 看看（多半是 CI 红）。"
    fi
    return 0
  fi

  # 6a. 修复那一轮推了 head、还没召唤：iterate 不再在 runner 上等 6 分钟冷却，冷却过了由这里召唤。
  #     Codex 额度没恢复就不召唤、不等冷却，直接请 Claude 审（带上 fix-round，轮数照样累加）。
  if [ "$summon_at" = 0 ] && [ "$m7_round" -gt 0 ]; then
    if codex_out; then
      hand_to_claude quota "<!-- codex-review-head: $H -->" "<!-- fix-round: $m7_round -->"
    elif [ $((now - last_review_at)) -ge 360 ]; then
      summon_fix_round "$m7_round"
    else
      echo "  等召唤冷却"
    fi
    return 0
  fi

  # 6b / 6c. 最近一次召唤之后 Codex 的回应里，GitHub 不发事件的两种：👍，和什么都没有。
  #       读不到 reaction（collect_pr 没留 reactions 文件）就分不清「点了 👍」和「没回应」，
  #       这两条都不走，交给下面的规则 5。
  if [ "$summon_at" -gt 0 ] && [ -f "$dir/reactions" ]; then
    read -r thumbs eyes <"$dir/reactions"
    if [ "$thumbs" = 1 ]; then
      wake_merge "点了 👍" "<!-- pr-guard: codex-thumbs head=$H summon=$summon_id -->" "$woken"
      return 0
    fi
  fi

  # 6d. 摘要显示 Codex 审完 H、没意见：这就是结论，不再重审、也不换 Claude。审完不满 2 分钟先等：
  #     有意见的话 review 可能还在发，下一轮规则 4 会接住。H 上的 clean 评论自己叫醒过路径 C，算叫过一次。
  if [ "$summary_status" = clean ]; then
    [ $((now - summary_at)) -ge 120 ] || { echo "  Codex 刚审完，等它把结果发完"; return 0; }
    wake_merge "审查摘要显示审完了" "<!-- pr-guard: codex-summary head=$H comment=$summary_id -->" \
      $((summary_woken + receipt_h))
    return 0
  fi

  # 6c. Codex 没接这次召唤（读不到 reaction 就不走，理由同 6b）。
  if [ "$summon_at" -gt 0 ] && [ -f "$dir/reactions" ] && [ "$handed" = 0 ] && [ "$codex_concluded" = 0 ]; then
    local waited=$((now - summon_at))
    if [ "$codex_quota" = 1 ]; then
      hand_to_claude quota; return 0
    elif [ "$codex_comments" = 0 ] && [ "$codex_reviews" = 0 ] && [ "$eyes" = 0 ] && [ "$waited" -ge 300 ]; then
      hand_to_claude silent; return 0
    # Codex 审的过程中会先发（再改）一条状态评论，上一个 head 的 review / clean 评论也可能晚于召唤才到，
    # 这些都不是结论：20 分钟只看 H 上的 clean 评论和 review（审完没意见的摘要在 6d 就接走了）。
    elif [ "$waited" -ge 1200 ]; then
      hand_to_claude timeout; return 0
    fi
  fi

  # 6e. 摘要显示 Codex 正在审 H（打开 PR 时它自己就审）：再叫只会白花一次额度。20 分钟还在审就当卡住，往下走。
  if [ "$summary_status" = running ] && [ $((now - summary_at)) -lt 1200 ]; then
    echo "  Codex 正在审"; return 0
  fi

  # 5. 没意见也没合：重新请求审查。没人碰过的 head 10 分钟就叫（打开 PR 时不再有 runner 等 Codex 的 👍）。
  if ! { [ "$referenced" = 0 ] && [ "$idle" -ge 600 ]; } && [ "$idle" -lt 3600 ]; then
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

summary "### PR 巡检（${MODE}）"
load_quota
failed=0 unreadable=0 unreadable_labels="" unonboarded=0 unonboarded_labels=""
# 第一遍：所有 PR 都读进 $tmp/pr/<序号>/（collect_pr），额度证据收齐；第二遍才逐个 sweep_pr 动手。
k=0 queued=""
for entry in $repos; do
  # 仓库名和分支名都不含 : 和空白。
  repo="${entry%%:*}" rest="${entry#*:}"
  private="${rest%%:*}" default_branch="${rest#*:}"
  label="$(repo_label "$repo" "$private")"
  # 私有仓库的 gh 报错里有仓库名，藏起来的（hidden）吞掉，只留一句通用警告。
  err=/dev/stderr
  ! hidden "$private" || err=/dev/null
  if ! prs="$(gh api --paginate "repos/$repo/pulls?state=open&per_page=100" --jq '
      .[] | select(.draft | not)
      | select(.head.repo.full_name == .base.repo.full_name)
      | select((.title | contains("[no-codex-merge]") or contains("[no-claude]")) | not)
      | select((.head.ref // "") | startswith("agent/") | not)
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
      # 没接共享自动化，但有开着的 PR：这些 PR 一个都不会被审或合，而每个 head 只
      # 告警一次，告完就再无声音（MEL-308：三个仓库这样卡了两周，5 个 PR 全停）。
      # 所以每轮都在 run 摘要里点名一次，让日常体检看得见，不用翻 PR 评论。
      3) base=- unonboarded=$((unonboarded + 1)) unonboarded_labels="$unonboarded_labels $label" ;;
      *)
        # 读不到调用桩（多半是令牌没有 Contents 读权限）：退回旧规则，
        # 只管默认分支是 develop 的仓库里合进 develop 的 PR，别的一概不碰（也不告 unwatched）。
        unreadable=$((unreadable + 1)) unreadable_labels="$unreadable_labels $label"
        [ "$default_branch" = develop ] || continue
        base=develop legacy=1 ;;
    esac
  fi
  # 私有仓库的分支名也是私密的，只给公开仓库打。
  if ! hidden "$private"; then
    if [ "$base" = - ]; then echo "$repo: 没接共享审查自动化"; else echo "$repo: 集成分支 $base"; fi
  fi

  for p in $prs; do
    n="${p%%:*}" pr_base="${p#*:}" watched=1
    if [ "$base" = - ] || [ "$pr_base" != "$base" ]; then
      [ "$legacy" = 0 ] || continue
      watched=0
    fi
    if hidden "$private"; then pr_label="$label"; else pr_label="$repo#$n"; fi
    k=$((k + 1)) dir="$tmp/pr/$k"
    mkdir -p "$dir"
    echo "$repo $n $private $base $watched $pr_label" >"$dir/meta"
    # 一个 PR 出错不拖累其它 PR；子 shell 里重开 -e（|| 语境下 -e 会失效，所以不用 ||）。
    set +e
    (set -e; collect_pr "$repo" "$n") 2>"$err"
    rc=$?
    set -e
    if [ "$rc" = 0 ]; then queued="$queued $k"; else echo "::warning::$pr_label 巡检出错（exit ${rc}）"; failed=1; fi
  done
done
# 第二遍：额度状态已经是这一轮所有 PR 的证据算出来的。第一遍读完所有仓库要一阵子，这期间 Codex 可能
# 已经审完、点了 👍、回了意见，所以动手前把这个 PR 再读一遍，按新读到的动手（额度状态不跟着改，下一轮
# 再并进来）；只比 head 不够（Codex 2026-10-16 的 P2）。
for k in $queued; do
  dir="$tmp/pr/$k"
  read -r repo n private base watched pr_label <"$dir/meta"
  err=/dev/stderr
  ! hidden "$private" || err=/dev/null
  set +e
  (set -e; fetch_pr "$repo" "$n"; sweep_pr "$repo" "$n" "$private" "$base" "$watched") 2>"$err"
  rc=$?
  set -e
  [ "$rc" = 0 ] || { echo "::warning::$pr_label 巡检出错（exit ${rc}）"; failed=1; }
done
save_quota
if [ "$unreadable" -gt 0 ]; then
  echo "::warning::$unreadable 个仓库读不到合并调用桩，按旧规则只扫默认分支是 develop 的（多半是 CODEX_TRIGGER_TOKEN 缺 Contents 权限）：${unreadable_labels# }"
fi
# 每轮都报，不跟着 head 去重：仓库漏接是仓库级的，换个 head 也不会自己好。
if [ "$unonboarded" -gt 0 ]; then
  echo "::warning::$unonboarded 个仓库有开着的 PR 但没接共享自动化，这些 PR 不会被审也不会被合，跑 ./onboard.sh <仓库> <python|node> 接上：${unonboarded_labels# }"
  summary "- 没接共享自动化却有开着的 PR（$unonboarded 个仓库，跑 \`./onboard.sh <仓库> <python|node>\`）：${unonboarded_labels# }"
fi
exit "$failed"
