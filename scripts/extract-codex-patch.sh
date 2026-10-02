#!/usr/bin/env bash
#
# 从 Codex 云端的那条回复里取出它贴的补丁。
#
#   extract-codex-patch.sh <回复正文文件> <补丁落点>
#
# 打印一行 reason=<码>。只有 ok 才写补丁文件并退 0，其余一律退 1、不写文件：
#
#   ok              恰好一个 diff 代码块，正文已写进 <补丁落点>
#   many-diffs      两个或更多 —— 分不清该用哪一段，不猜
#   truncated       diff 块开了没合上（GitHub 评论有长度上限，回复会被截断）
#   no-environment  回复是「要先给这个仓库建 Codex 云端环境」
#   codex-quota     回复是额度 / 限流提示
#   no-diff         回复里没有 diff 代码块
#
# 判不准就算失败（fail closed）。回复是外部输入，打上一段猜来的补丁等于让它
# 直接改仓库 —— 而后面那一步带着写权限令牌把结果推出去。
#
# 先数 diff 块、再看「为什么没有」。反过来的话，一段本来好用的补丁只要正文里
# 提到额度就被当成额度提示扔掉（这个仓库自己的 review 意见里就有这种词）。
set -euo pipefail

reply="${1-}"
patch_out="${2-}"

fail() {
  printf 'reason=%s\n' "$1"
  exit 1
}

if [ -z "$reply" ] || [ -z "$patch_out" ]; then
  echo 'usage: extract-codex-patch.sh <reply-file> <patch-out-file>' >&2
  exit 2
fi
[ -r "$reply" ] || fail no-diff

# 围栏代码块按 CommonMark 数：行首最多 3 个空格，3 个以上的 ` 或 ~，收尾围栏
# 必须是同一种字符、不短于开头那一条。只认 info string 恰好是 diff 的块 ——
# 留言里就是这么要求它的，而「随便哪个围栏块都算补丁」会把它回复末尾的
# 「Testing」清单也读成补丁。
#
# 不用 {0,3} 这类区间量词：各家 awk 对它支持度不一（本机 macOS 上也要跑这套
# 测试），缩进和围栏长度一律用 substr 自己数。
#
# 一个 diff 块里每一行都带 ` / + / - / @ 前缀，所以补丁正文里不会出现顶格的
# ``` 把块提前收掉 —— 补丁改的正好是 markdown 文件也一样。
#
# shellcheck disable=SC2016  # 单引号里是 awk 程序，$0 是 awk 的字段
summary="$(awk -v out="$patch_out.raw" '
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  {
    line = $0
    ind = 0
    while (ind < 3 && substr(line, ind + 1, 1) == " ") ind++
    s = substr(line, ind + 1)
    ch = substr(s, 1, 1)
    n = 0
    if (ch == "`" || ch == "~") { while (substr(s, n + 1, 1) == ch) n++ }

    if (open) {
      if (ch == fence_ch && n >= fence_n && trim(substr(s, n + 1)) == "") {
        open = 0
        if (is_diff) blocks++
        is_diff = 0
        next
      }
      if (is_diff && blocks == 0) body = body line "\n"
      next
    }

    if (n >= 3) {
      open = 1; fence_ch = ch; fence_n = n
      is_diff = (tolower(trim(substr(s, n + 1))) == "diff")
      next
    }
  }
  END {
    # 开了没合上的 diff 块 = 回复被截断，一个字都不信：截在 hunk 中间的补丁
    # git apply 会拒，截在 hunk 边界上的却打得上，推出去就是半截修复。
    if (open && is_diff) { print "0 truncated"; exit }
    printf "%d %s\n", blocks, (blocks == 1 ? "one" : "none")
    if (blocks == 1) printf("%s", body) > out
  }
' "$reply")" || fail no-diff

blocks="${summary%% *}"
state="${summary##* }"

case "$state" in
  truncated) fail truncated ;;
  one)
    [ -s "$patch_out.raw" ] || fail no-diff
    mv -- "$patch_out.raw" "$patch_out"
    printf 'reason=ok\n'
    exit 0
    ;;
esac

[ "$blocks" -lt 2 ] || fail many-diffs

# 没有 diff 块时才看回复在说什么。这两类处置不同：缺环境要人去建一个（告警里
# 得说清），额度只要等。其余一律 no-diff。
body="$(cat -- "$reply")"
shopt -s nocasematch
if [[ $body == *'to use codex here'* && $body == *'create an environment'* ]]; then
  fail no-environment
fi
for marker in 'usage limit' 'rate limit' 'too many requests' 'out of credits' 'quota'; do
  [[ $body == *"$marker"* ]] || continue
  fail codex-quota
done
shopt -u nocasematch
fail no-diff
