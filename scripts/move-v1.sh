#!/usr/bin/env bash
# 每天把 v1 标签移到 develop 上 CI 全绿的最新提交。各仓库的调用桩钉的是 @v1，所以这一步
# 就是「发布」：合进 develop 不改变任何仓库，v1 动了才生效。以前它在人手里，每个合并的 PR
# 都要问一次「要不要移 v1」，问多了就有人忘 —— MEL-290 那次 19 个仓库照旧踩着修好的 bug。
# 2026-10-08 起改成每天自动移一次（她定的），移了推一条手机通知，说清移了哪些 PR、怎么回滚。
#
# 只往前挪：落点必须在 v1 之后的同一条线上（快进），不然不动、推通知等人看。
# 手动回滚：Actions → Move v1 → Run workflow，to 填旧的 sha（必须在 develop 这条线上）。
#
# 环境变量：
#   REPO          owner/名
#   GH_TOKEN      读 CI 结果、比较提交用（job 自带的令牌就够）
#   WRITE_TOKEN   改标签用（SELF_WORKFLOWS_TOKEN：带 Contents + Workflows 写权限）
#   TO            手动指定落点（空 = develop 上 CI 全绿的最新提交）
#   DRY_RUN       true = 只说会做什么
#   UNATTENDED    true = 定时跑的，没人看日志，出事推手机
#   PUSHOVER_TOKEN / PUSHOVER_USER
set -euo pipefail

: "${REPO:?REPO 没设}"
summary_file="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
say() { printf '%s\n' "$1" | tee -a "$summary_file"; }

push() { # push <标题> <正文>
  [ -n "${PUSHOVER_TOKEN:-}" ] && [ -n "${PUSHOVER_USER:-}" ] || return 0
  curl -sf -X POST https://api.pushover.net/1/messages.json \
    --form-string "token=$PUSHOVER_TOKEN" --form-string "user=$PUSHOVER_USER" \
    --form-string "title=$1" --form-string "message=${2:0:1000}" >/dev/null 2>&1 || true
}
# 出事才推，而且只在没人看着（定时）的时候推；手动跑时她就在页面上。
trouble() {
  say "### ⚠️ $1"
  say "$2"
  [ "${UNATTENDED:-}" = true ] && push "🤖 v1 没有移：$1" "$2"
  return 0
}

# ahead / identical = 这个提交在 develop 这条线上（develop 就是它，或者在它后面）。
develop_status() { gh api "repos/$REPO/compare/$1...develop" --jq .status; }

current="$(gh api "repos/$REPO/git/ref/tags/v1" --jq '.object.sha')"

if [ -n "${TO:-}" ]; then
  goal="$(gh api "repos/$REPO/commits/$TO" --jq .sha)"
  # 回滚也只认 develop 这条线上的提交：别的分支上的提交没人审过。
  on_develop="$(develop_status "$goal")"
  case "$on_develop" in
    ahead | identical) ;;
    *) trouble "指定的提交不在 develop 上" "\`${goal:0:7}\` 不在 develop 这条线上（${on_develop}），没有动。"; exit 1 ;;
  esac
else
  # develop 上 CI 跑绿了的最新一个提交。CI 只在推到 develop 时跑（合并 PR 就是一次推送），
  # 所以每个合进来的版本都有一条记录；红的、还没跑完的都不算。
  goal="$(gh api "repos/$REPO/actions/workflows/self-ci.yml/runs?branch=develop&event=push&status=success&per_page=1" \
    --jq '.workflow_runs[0].head_sha // empty')"
  if [ -z "$goal" ]; then
    trouble "develop 上找不到 CI 全绿的提交" "这一轮没有动，v1 还在 \`${current:0:7}\`。"
    exit 0
  fi
fi

if [ "$goal" = "$current" ]; then
  say "v1 已经在 \`${goal:0:7}\`，不用动。"
  exit 0
fi

# develop 被强推过、新的 CI 还没跑完或是红的时候，上面那条绿记录指的可能是已经不在 develop 上的
# 旧提交。移过去就把 v1 带离了 develop 这条线，之后每天都会报「不在这条线后面」。
if [ -z "${TO:-}" ]; then
  on_develop="$(develop_status "$goal")"
  case "$on_develop" in
    ahead | identical) ;;
    *)
      trouble "最新的绿提交已经不在 develop 上" "\`${goal:0:7}\` 相对 develop 是 ${on_develop}（develop 可能被强推过），这一轮没有动，v1 还在 \`${current:0:7}\`。"
      exit 0
      ;;
  esac
fi

cmp="$(gh api "repos/$REPO/compare/$current...$goal")"
status="$(jq -r .status <<<"$cmp")"
if [ -z "${TO:-}" ] && [ "$status" != ahead ]; then
  # 有人手动把 v1 挪到了别处（更新的位置，或者另一条线上）：自动这一步不跟人抢。
  trouble "v1 不在 develop 的这条线后面" "v1 在 \`${current:0:7}\`，develop 上最新的绿提交 \`${goal:0:7}\` 相对它是 ${status}。自动移只往前挪，这次没有动，请看一眼。"
  exit 0
fi

# 这一次带上了哪些改动：合并进来的每个 PR 一行（squash 合并的提交标题就是 PR 标题）。
# 手动往回退时列的是撤掉了哪些。
verb=移到
if [ "$status" = behind ]; then
  verb=退回到
  cmp="$(gh api "repos/$REPO/compare/$goal...$current")"
fi
changes="$(jq -r '[.commits[] | "- " + (.commit.message | split("\n")[0])] | .[-8:] | join("\n")' <<<"$cmp")"
count="$(jq -r '.commits | length' <<<"$cmp")"
rollback="Actions → Move v1 → Run workflow，to 填 ${current:0:7}"

if [ "${DRY_RUN:-}" = true ]; then
  say "### 会把 v1 从 \`${current:0:7}\` $verb \`${goal:0:7}\`（$count 个提交，没有真的移）"
  say "$changes"
  exit 0
fi

if [ -z "${WRITE_TOKEN:-}" ]; then
  trouble "缺改标签用的令牌" "SELF_WORKFLOWS_TOKEN 没设，v1 还在 \`${current:0:7}\`。"
  exit 1
fi
# 普通的 GITHUB_TOKEN 改不了指向含 workflow 改动的提交的标签，所以只这一条用带 Workflows 权限的那把。
GH_TOKEN="$WRITE_TOKEN" gh api -X PATCH "repos/$REPO/git/refs/tags/v1" -f "sha=$goal" -F force=true --silent

say "### ✅ v1 从 \`${current:0:7}\` $verb \`${goal:0:7}\`（$count 个提交）"
say "$changes"
say ""
say "回滚：$rollback"
push "🤖 v1 已更新（$count 个提交）" "各仓库从现在起用新版本：
$changes

回滚：$rollback"
