#!/usr/bin/env bats
# scripts/extract-codex-patch.sh：从 Codex 云端那条回复里取补丁。
#
# 这段判定决定「一条外部评论要不要被当成补丁打进仓库」，而下一步带着写权限令牌
# 把结果推出去。所以每一条判不准的路都要有判定，而且一律落到失败那一侧。
#
# 回复的真实长相来自 MEL-266 的实测（gh-workflows PR #20 的 5933906506 号评论）：
# 一段 ### Summary、一个 ```diff 块、一串 **Testing** 清单。

load test_helper/common

EXTRACT="$REPO_ROOT/scripts/extract-codex-patch.sh"

setup() {
  cd "$BATS_TEST_TMPDIR" || return
  PATCH="$BATS_TEST_TMPDIR/out.diff"
  : >reply.md
}

# 一段最小的合法补丁
DIFF='diff --git a/a.sh b/a.sh
index 1111111..2222222 100644
--- a/a.sh
+++ b/a.sh
@@ -1 +1 @@
-echo old
+echo new'

extract() { run bash "$EXTRACT" reply.md "$PATCH"; }

reason() { printf '%s\n' "$output" | sed -n 's/^reason=//p'; }

@test "extract: the real reply shape yields exactly the diff, nothing around it" {
  printf '### Summary\n\n* Restored the `auto` path. [a.shL1](https://github.com/o/r/blob/x/a.sh#L1)\n\n### Complete unified diff\n\n```diff\n%s\n```\n\n**Testing**\n\n* ✅ `bats tests/`\n* ✅ `git diff --check`\n' "$DIFF" >reply.md

  extract

  assert_equal "$status" 0
  assert_equal "$(reason)" ok
  assert_equal "$(cat "$PATCH")" "$DIFF"
}

@test "extract: a reply with no diff block is a failure, not an empty patch" {
  printf '### Summary\n\n* Nothing to change here.\n' >reply.md
  extract
  assert_equal "$status" 1
  assert_equal "$(reason)" no-diff
  [ ! -e "$PATCH" ]
}

# 两段就不猜。贴两段的常见长相是「先给一版，再给个替代方案」，挑错一段就是把
# 没人要的改动推进仓库。
@test "extract: two diff blocks are refused rather than guessed between" {
  printf '```diff\n%s\n```\n\nor, if you prefer:\n\n```diff\n%s\n```\n' "$DIFF" "$DIFF" >reply.md
  extract
  assert_equal "$status" 1
  assert_equal "$(reason)" many-diffs
  [ ! -e "$PATCH" ]
}

# GitHub 的评论有长度上限，长补丁会被截断，截断的回复里那个 ``` 收尾围栏就没了。
# 截在 hunk 中间 git apply 会拒，截在 hunk 边界上的却打得上 —— 推出去就是半截修复。
@test "extract: an unclosed diff block is treated as a truncated reply" {
  printf '### Summary\n\n```diff\n%s\n' "$DIFF" >reply.md
  extract
  assert_equal "$status" 1
  assert_equal "$(reason)" truncated
  [ ! -e "$PATCH" ]
}

@test "extract: the missing-environment reply gets its own reason" {
  printf 'To use Codex here, [create an environment for this repo](https://chatgpt.com/codex/cloud/settings/environments).\n' >reply.md
  extract
  assert_equal "$status" 1
  assert_equal "$(reason)" no-environment
}

@test "extract: a quota or rate-limit reply gets its own reason" {
  printf 'You have reached your Codex usage limits.\n' >reply.md
  extract
  assert_equal "$status" 1
  assert_equal "$(reason)" codex-quota

  printf 'Rate limit exceeded, try again in an hour.\n' >reply.md
  extract
  assert_equal "$status" 1
  assert_equal "$(reason)" codex-quota
}

# 顺序要紧：先数 diff 块，再看「为什么没有」。反过来写的话，一段本来好用的补丁
# 只要正文里提到额度就被当成额度提示扔掉 —— 而这个仓库自己的 review 意见里就
# 到处是 quota 这个词。
@test "extract: a usable patch survives a summary that happens to mention quota" {
  printf '### Summary\n\n* Fixed the quota classifier so a rate limit is no longer read as a usage limit.\n\n```diff\n%s\n```\n' "$DIFF" >reply.md
  extract
  assert_equal "$status" 0
  assert_equal "$(cat "$PATCH")" "$DIFF"
}

# 只认 info string 恰好是 diff 的围栏块。它回复末尾那串 Testing 命令、或者任何
# 别的代码块，都不是补丁。
@test "extract: only a diff-tagged fence counts, not any other code block" {
  printf '```bash\nbats tests/\n```\n\n```\n%s\n```\n' "$DIFF" >reply.md
  extract
  assert_equal "$status" 1
  assert_equal "$(reason)" no-diff
}

# 另一个方向：别的围栏块里恰好有一行 ```diff（比如 Codex 在解释「请把补丁贴成
# 这样」），不能被当成一个补丁块开头。
@test "extract: a diff fence quoted inside another code block opens nothing" {
  printf '```markdown\n```diff\n...\n```\n' >reply.md
  extract
  assert_equal "$status" 1
  assert_equal "$(reason)" no-diff
}

# 补丁改的正好是 markdown 文件时，正文里会出现 ``` 这一行 —— 但 diff 的每一行都
# 带 ` / + / - 前缀，所以收不掉外面那个块。守住这一点，否则改 README 的补丁一律
# 被读成「两个块」或「截断」。
@test "extract: a patch that itself adds a code fence does not close the block early" {
  md='diff --git a/README.md b/README.md
--- a/README.md
+++ b/README.md
@@ -1,3 +1,4 @@
 # title
+```
 text
 more'
  printf '```diff\n%s\n```\n' "$md" >reply.md
  extract
  assert_equal "$status" 0
  assert_equal "$(cat "$PATCH")" "$md"
}

@test "extract: a diff block with nothing in it is a failure" {
  printf '```diff\n```\n' >reply.md
  extract
  assert_equal "$status" 1
  assert_equal "$(reason)" no-diff
  [ ! -e "$PATCH" ]
}

@test "extract: an unreadable reply file fails closed" {
  run bash "$EXTRACT" "$BATS_TEST_TMPDIR/not-there.md" "$PATCH"
  assert_equal "$status" 1
  assert_contains "$output" 'reason=no-diff'
}
