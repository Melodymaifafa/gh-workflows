# gh-workflows

Melody 名下所有仓库共用的 GitHub Actions 逻辑。**改这里，所有仓库同时生效。**

## 分支标准

- `develop` 收 PR，所有 workflow 都由「PR 打向 develop」触发
- `main` 只做 `develop` 的 fast-forward（约两周一次），保存真正能用的版本
- 升级命令：`git push origin develop:main`（绝不用 merge / squash，否则两个分支会分叉）

## 三个工作流

| 文件 | 什么时候跑 | 干什么 |
|---|---|---|
| `ci.yml` | 每个 PR、推送到 main/develop | 装依赖 → lint → 测试 |
| `claude-codex-iterate.yml` | Codex 提交 review 后 | Claude 读评论、改代码、跑验证、push、发中文总结，然后召唤复审 |
| `codex-approved-merge.yml` | PR 开启 / 有人喊 `@codex review` | 等 Codex 无意见 + CI 全绿，自动 squash 合入 develop |

## 接一个新仓库

```
./onboard.sh <repo> <python|node>
```

脚本会建 develop、提交调用桩、把 main FF 过去、刷密钥。之后还剩**一件必须手动做的事**：在 ChatGPT 里把 Codex connector 授权给这个仓库（没有 API）。

## 调用桩长什么样

`stubs/` 里三个文件就是全部。每个仓库只放这三个，逻辑全在本仓库。例如：

```yaml
jobs:
  ci:
    uses: Melodymaifafa/gh-workflows/.github/workflows/ci.yml@v1
    with:
      runtime: node
```

`runtime` 只有 `python` 和 `node` 两种，分别对应 `uv + ruff + pytest` 和 `npm + npm test`。仓库有特殊情况时可以用 `install_cmd` / `lint_cmd` / `test_cmd` 单独覆盖；传 `skip` 表示该仓库暂时没有 lint 或测试。

## 密钥

四个，都在各仓库的 Settings → Secrets 里，由 `onboard.sh` 从 `~/.config/gh-workflows/secrets.env` 刷进去。

| 密钥 | 缺了会怎样 |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude 迭代不跑（`claude setup-token` 生成，`sk-ant-oat01-` 开头） |
| `CODEX_TRIGGER_TOKEN` | 无法自动召唤 Codex 复审，需人工评论 `@codex review` |
| `PUSHOVER_TOKEN` / `PUSHOVER_USER` | 流水线断了不会推手机通知 |

`CODEX_TRIGGER_TOKEN` 必须是真人账号建的 fine-grained PAT（GitHub Actions 自带的 bot token 发 `@codex review` 会被 Codex 拒绝）。**一个 PAT 可以勾选多个仓库**，接新仓库时去 PAT 设置里把新仓库加进去即可，不用重新建。

## 版本

各仓库的调用桩固定引用 `@v1`。改完这里的逻辑后要移动 tag 才会生效：

```
git tag -f v1 && git push -f origin v1
```

## 踩过的坑

- **不要放宽 `--allowedTools`**：Codex 的 review 正文是外部输入，直接进 Claude 的 prompt，而那个 token 有写权限。只放行具体命令，别用 `Bash(git:*)`。
- **`--allowedTools` 是全量清单**：`Edit,MultiEdit,Write` 不列出来 Claude 就改不了任何文件，只会干烧轮数。
- **绿勾 ≠ 有产出**：确认 Claude 真干了活要看 PR 时间线有没有评论和 commit。
- **`@codex review` 会被限流静默**：连发几次后连 👀 都不回，约 10 分钟恢复。iterate 工作流为此做了 6/12/18 分钟三窗口重试 + 回执验证。
- **秒合并的 PR** 会让 Codex 迟到的 review 落在已关闭的 PR 上，job 被跳过是正常现象。
