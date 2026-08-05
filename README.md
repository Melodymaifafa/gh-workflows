# gh-workflows

Melody 名下所有仓库共用的 GitHub Actions 逻辑。**改这里，所有仓库同时生效。**

## 分支标准

- `develop` 收 PR，所有 workflow 都由「PR 打向 develop」触发
- `main` 只做 `develop` 的 fast-forward（约两周一次），保存真正能用的版本
- 升级方式：`ff-main.yml` 每月 1 / 15 号自动跑（约每两周），也能手动点 **Actions → Fast-forward main**。绝不用 merge / squash —— 一旦产生合并记录，两条分支从此永久分叉，再也回不到快进。
- 自动挪安全的前提是**快进不销毁任何东西**：main 原来那个 commit 是新 commit 的祖先，一直在历史里。发现问题就把指针挪回去 —— `gh api -X PATCH repos/<slug>/git/refs/heads/main -f sha=<旧 sha> -F force=true`（往回是非快进，所以要 `force`；往前不用）。旧 sha 在 Actions 那次 run 的摘要里，或仓库 Insights → Network。
- 定时挪的代价是 `main` 不再等于「我确认过这版能用」。两道闸门是那句话的自动替代品：
  - **泡够 7 天**（`min_age_days`）—— 落点不是 develop 的最新位置，而是它 7 天前的位置。追到最新会让 main 和 develop 一模一样，那就没有可退的点了；泡 7 天保证 main 上每一笔都在 develop 上活过一周。填 `0` 关掉。
  - **CI 全绿**（`require_green`）—— 落点 commit 有失败、还在跑、或压根没跑过 CI，都跳过并推一条 Pushover。「没跑过 CI」不是「没问题」，是「不知道」。
  - 两道都想无视：手动跑一次，`min_age_days` 填 0、取消勾选 `require_green`。
- 手动等价命令：`git push origin origin/develop:main`。**注意左边要写 `origin/develop`,不是 `develop`** —— `develop` 指的是你本地那个分支,忘了 `git fetch` 就会把 main 推到一个过期的位置,而且这仍然是一次合法快进,git 不报错、你也看不出来。workflow 走 API 读远端,不存在这个坑。

## 三个工作流

| 文件 | 什么时候跑 | 干什么 |
|---|---|---|
| `ci.yml` | 每个 PR、推送到 main/develop | 装依赖 → lint → 测试 |
| `claude-codex-iterate.yml` | Codex 提交 review 后 | Claude 读评论、改代码、跑验证、push、发中文总结，然后召唤复审 |
| `codex-approved-merge.yml` | PR 开启 / 有人喊 `@codex review` | 等 Codex 无意见 + CI 全绿，自动 squash 合入 develop |
| `ff-main.yml` | 每月 1 / 15 号 09:00，也可手动点 | 把 main 快进到 develop 上「泡够 7 天」的那个位置。CI 不全绿就跳过并推手机通知；分叉了直接拒绝 |

## 开一个新项目（从零）

```
./newrepo.sh <name> <python|node> [--public]
```

建远端仓库（默认 private）→ 装自动化 → 默认分支改 `develop` → 克隆到 `~/projects/<name>`。新仓库还没有依赖清单，CI 三步默认 `skip`；写完代码删掉 `ci.yml` 里的 `install_cmd` / `lint_cmd` / `test_cmd` 三行就开启。

## 接一个已有仓库

```
./onboard.sh <repo> <python|node>
```

脚本会建 develop、提交调用桩、把 main FF 过去、把默认分支改成 `develop`、刷密钥。默认分支只会在 main 快进成功后自动切；如果被 GitHub 拒绝，脚本会打印需要手动执行的命令。

仓库没有依赖清单 / lint 配置 / 测试时，把对应步骤设成 `skip`，避免第一天就满屏红叉：

```
INSTALL_CMD=skip LINT_CMD=skip TEST_CMD=skip ./onboard.sh <repo> node
```

**本仓库已是 public（2026-07-30），公开和私有仓库都能接。** 之前是 private 时，公开仓库调用它会失败得毫无线索：run 存在但 0 秒结束、一个 job 都没有、只报 "workflow file issue" —— 跨可见性调用不被允许，而报错完全不提这回事。顺带好处：公开仓库的 Actions 分钟数免费无上限，私有仓库每月 2000 分钟。

Codex connector 是账号级授权，新仓库无需单独授权（2026-07-29 在 learn-api-integrations 实测：新开的 PR 2 分钟内就被自动 review 并 👍）。

## 调用桩长什么样

`stubs/` 里三个文件就是全部。每个仓库只放这三个，逻辑全在本仓库。例如：

```yaml
jobs:
  ci:
    uses: Melodymaifafa/gh-workflows/.github/workflows/ci.yml@v1
    with:
      runtime: node
```

`runtime` 三种：`python`（`uv + ruff + pytest`）、`node`（`npm + npm test`）、`shell`（`actionlint + shellcheck`，给只有 bash 脚本和 workflow YAML 的仓库用，本仓库自己就走这个）。仓库有特殊情况时可以用 `install_cmd` / `lint_cmd` / `test_cmd` 单独覆盖；传 `skip` 表示该仓库暂时没有 lint 或测试。

## 密钥

四个，都在各仓库的 Settings → Secrets 里，由 `onboard.sh` 从 `~/.config/gh-workflows/secrets.env` 刷进去。**`secrets.env.example` 是那个文件的模板** —— 键名、各自干什么、去哪生成都在里面；真值只留在 `~/.config` 下（本仓库是 public，值放进仓库就等于公开）。

| 密钥 | 缺了会怎样 |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude 迭代不跑（`claude setup-token` 生成，`sk-ant-oat01-` 开头） |
| `CODEX_TRIGGER_TOKEN` | 无法自动召唤 Codex 复审，需人工评论 `@codex review` |
| `PUSHOVER_TOKEN` / `PUSHOVER_USER` | 流水线断了不会推手机通知 |

`CODEX_TRIGGER_TOKEN` 必须是真人账号建的 fine-grained PAT（GitHub Actions 自带的 bot token 发 `@codex review` 会被 Codex 拒绝）。权限选 **All repositories** + Metadata read + Issues/PR read & write —— 覆盖全部仓库，接新仓库不用回去改 PAT。

## 本仓库自己也接了（2026-07-30）

在这之前，这个仓库给 7 个仓库做自动化，自己一次 run 都没跑过 —— 而它是改动风险最高的一个：一处改错，7 个仓库同时停摆。

调用桩放在 `.github/workflows/self-*.yml`。**必须换个文件名** —— 定义文件已经占了 `ci.yml` 那四个名字，同名会把定义覆盖掉（试过一次，当场翻车）。

**自动合入是安全的，因为各仓库钉的是 `@v1`。** 合进 develop / main 不改变任何仓库的行为，只有手动移 `v1` 标签才生效 —— 那一步就是真正的闸门，而它一直在人手里。

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
- **密钥只写不读，个人账号也没有账号级密钥**：存进仓库后连 API 都取不回值（`gh api repos/X/actions/secrets/NAME` 只返回名字和日期），共享密钥是 organization 才有的功能。所以 `secrets.env` 是唯一母本 —— 在网页上手填过的值必须补回母本，否则接新仓库时无处可取（2026-07-30 为此翻了半天 `~/.claude/history.jsonl`）。
- **Regenerate PAT 会立刻作废旧值**：换完要把所有仓库的 secret 一起刷新。漏掉的那个 CI 照样绿，只有 Codex 复审那步静默停住。
- **接完要把仓库默认分支改成 `develop`**：`onboard.sh` 起手要求默认分支是 `main`（它靠 main 建 develop），但完成后会自动改成 `develop`。如果这步失败，必须手动补；否则 `gh pr create` 不带 `--base` 会打向默认分支。linear-agent-team 忘了改，agent 开的 3 个 PR 全合进 main，develop 停在初始 commit（2026-07-30）。
