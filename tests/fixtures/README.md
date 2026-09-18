# 测试 fixture

真数据用只读 `gh api` / `gh run view --log` 抓取。私有调用方仓库名在 URL 里换成了 `private-caller`，私有代码内容已替换。统一的假 head：`1a7e81f6b5f27f0a1dbc33c6fafda1bb86f1483d`（下文记作 H）。

## codex/（真数据）

- `quota-comment.json` — Codex 额度用完的 issue 评论（私有调用方 PR #7，PR 08:02:54 开，评论 08:03:00；PR head 就是 H）。
- `findings-review.json` — Codex 有问题的 review 对象（gh-workflows #7，commit_id `a4c2a6bc…`）。
- `findings-review-comments.json` — 上面那个 review 的行内评论列表（P2 一条）。
- `clean-comment.json` — Codex「Didn't find any major issues」评论，含 `**Reviewed commit:** \`b03804c84c\``（gh-workflows #7）。
- `m1-comment.json` — 老格式 M1（`@codex review` + `codex-review-head: b03804c8…`），OWNER 写（gh-workflows #7）。
- `reactions-eyes.json` — Codex 在 `@codex review` 评论上留的 👀 reaction 列表（gh-workflows #7）。
- `reactions-thumbsup.json` — Codex 在 PR 正文上留的 👍 reaction 列表（gh-workflows #7）。
- `summon-clean-sequence.json` — 私有调用方 PR 的一次召唤→干净：M1（d69c0a42…，22:04:30）+ Codex clean 评论（22:10:25）。

## sdk/（claude-code-action 的 execution_file，JSON 数组）

- `exec-429-weekly-limit.json` — 真数据，2026-08-22 iterate 跑挂的那次：`rate_limit_event.status` rejected、`resetsAt` 1787569200、结果 `api_error_status` 429、372 ms、$0。注意结果 `subtype` 是 "success" 而 `is_error` 是 true。init 消息删了长列表。
- `exec-401-auth.json` — 照 429 改的：`api_error_status` 401，无 rate_limit_event → auth。
- `exec-529-overloaded.json` — 照 429 改的：`api_error_status` 529 → *-failed。
- `exec-rate-limit-rejected-no-reset.json` — rate_limit_event rejected 但没 `resetsAt`、结果没 `api_error_status` → *-quota，until = 现在 + 21600。
- `exec-success-structured.json` — 成功，结果带 `structured_output`（verdict findings，1 条 P1）。
- `exec-success-clean-p2.json` — 成功，`structured_output` verdict clean，只有 1 条 P2。
- `exec-success-no-structured.json` — 成功但没有 `structured_output` → 不算审过，绝不当 clean。
- `exec-empty.json` — 空数组 `[]` → 不算审过。

## forged/（伪造标记，全都不该被信任）

真 claude[bot] 评论对象（association NONE）换了正文；review 用真 Codex review 对象换了作者。

- `claude-bot-clean-comment.json` — claude[bot] 发的 M4（`claude-review-clean: H`）。
- `claude-bot-findings-review.json` — claude[bot] 发的 M3 review（commit_id H）。
- `claude-bot-fix-retry-review.json` — claude[bot] 发的 M5 review（`fix-retry: head=H review=4863267293`）。
- `claude-bot-m1-comment.json` — claude[bot] 发的 M1，带 `fix-round: 0`（想把轮数清零）。
- `claude-bot-alert-comment.json` — claude[bot] 发的 M6（`reason=no-fix`），想冒充「已停」。
- `claude-bot-fallback-comment.json` — claude[bot] 发的 M2（`reason=quota`）。
- `contributor-clean-comment.json` — 非 OWNER 的真人（CONTRIBUTOR）发的 M4。
