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

## 工作流

| 文件 | 什么时候跑 | 干什么 |
|---|---|---|
| `ci.yml` | 每个 PR、推送到 main/develop | 装依赖 → lint → 测试 |
| `claude-codex-iterate.yml` | Codex 或 Claude 代审提交意见后 | 选一个 fixer 读意见、改代码、跑验证、push、发中文总结，然后召唤复审；最多连修 5 轮。默认 Claude 先上，撞额度/限流/认证失效才换 Codex 接手 |
| `codex-approved-merge.yml` | PR 开启 / 有人喊 `@codex review` / Claude 代审通过 | 先等 Codex；Codex 不行就换 Claude 代审这一次。审核无意见 + CI 全绿，自动 squash 合入调用桩 `base_branch` 指定的分支（默认 develop） |
| `pr-sweeper.yml` | 定时（cron 写每 15 分钟，实测 2–7 小时一次；只在本仓库跑） | 扫 owner 名下所有仓库，集成分支取各仓库调用桩的 `base_branch`；给没人管的 PR 重新叫审、重修，卡住就推一次手机通知 |
| `ff-main.yml` | 每月 1 / 15 号 09:00，也可手动点 | 把 main 快进到 develop 上「泡够 7 天」的那个位置。CI 不全绿就跳过并推手机通知；分叉了直接拒绝 |

## 审核：Codex 优先，Claude 兜底（2026-09-18）

每一次审核请求都先问 Codex。出现下面任一情况，**这一次**改由 Claude 只读代审，结果由 owner 的 PAT 发出（这样下一环才会被触发）：

- Codex 回复「reached your Codex usage limits」（30 秒内发现）；
- 喊了 `@codex review` 5 分钟没有 👀 也没有结论；
- 20 分钟还没有结论。

没有「Codex 已坏」的全局开关：下一轮照样先问 Codex，它额度恢复就自动接回。Claude 代审只读（Read/Glob/Grep），看不到任何密钥，结论必须是合法 JSON 才算数；空结果一律当「没审过」，绝不当「通过」。**有意见的 head 永远不会被合并。**

机器之间靠藏在评论里的标记接力，只认 `github-actions[bot]` 或 OWNER 写的，`claude[bot]` 写什么都不算：

| 标记 | 谁写 | 意思 |
|---|---|---|
| `codex-review-head: H` | PAT（iterate / 巡检） | 请审 H；可带 `fix-round: N` 或 `pr-sweeper: kick` |
| `pr-guard: fallback head=H` | GITHUB_TOKEN | Codex 这次不行，换 Claude |
| `claude-review-findings: H` | PAT | Claude 代审有意见（一条 COMMENT review） |
| `claude-review-clean: H` | PAT | Claude 代审无意见，CI 绿就合 |
| `fix-retry: head=H review=ID` | PAT（巡检） | 上次修复没完成，再修一次 |
| `pr-guard: fix-round head=H round=N` | GITHUB_TOKEN | 第 N 轮修复已推送（轮数不靠召唤是否成功） |
| `pr-guard: alert head=H reason=R until=T` | 各环节 | 已告警 R，同一 head 同一原因只推一次 |

告警原因 R：`ci` `unmergeable` `conflict` `review-quota` `fix-quota` `auth` `pat-missing` `review-failed` `fix-failed` `no-fix` `round-cap` `retry-exhausted` `stalled` `unwatched`。额度类（`*-quota`）撞第二次只补一条带新恢复时间的静默标记，不再推送。

**巡检**（`pr-sweeper.yml` + `scripts/pr-sweep.sh`）是兜底：没人碰过的 head 空闲 30 分钟、或任何 head 空闲 60 分钟就重新叫审（每个 head 3 次、间隔 ≥ 60 分钟，之后告警 `stalled`，再每天一次共 7 天）；有意见但修复失败的 head 重修最多 2 次（撞额度的不算，但总数封顶 6 次），之后告警 `retry-exhausted`。停车的 head（`no-fix` `round-cap` `retry-exhausted`、CI 红）等人处理。没人管的 PR（仓库没接共享调用桩，或 PR 没打向集成分支）空闲 60 分钟后每个 head 告警一次 `unwatched`，不叫审不重修。

- **集成分支**：每个仓库从默认分支上的 `.github/workflows/codex-approved-merge.yml` 读 `base_branch`（本仓库读 `self-codex-approved-merge.yml`），没写就是 develop。读不到（多半是没设 `SWEEP_READ_TOKEN`）就按旧规则只扫默认分支是 develop 的仓库，run 里警告一次。
- **节奏**：cron 写的每 15 分钟，GitHub 实际 2–7 小时才跑一次，所以上面的 30 / 60 分钟只是下限。急的话手动点 **Actions → PR sweeper → Run workflow**，取消勾选 `dry_run` 才会动手。
- **开关**：本仓库的 Actions 变量 `SWEEP_MODE` = `off`（默认，没设也是 off）/ `dry`（只在 run 摘要里写「会做什么」）/ `live`。出问题先改回 `off`。
- **本仓库需要 4 个密钥**，巡检才能跑（2026-09-18 已加）；另加一个只给巡检用的 `SWEEP_READ_TOKEN`，见下方「密钥」。
- 本仓库是 public，run 日志人人能看：私有仓库只写 `repo-<HMAC 前 8 位>`，不写名字、分支名、PR 号和 SHA。

故意不管的：草稿、从 fork 开的 PR、标题带 `[no-codex-merge]` / `[no-claude]` 的 PR。叫审 3 次没结果的 head 之后只每天叫一次、共 7 天，然后不再叫；有冲突、已停车的 head 只告警一次。用内联副本、没接共享调用桩的仓库（如 Weibo--automation-android）：每个 PR 的每个 head 空闲 60 分钟后告警一次 `unwatched`，不叫审；私有仓库要等巡检读得到调用桩才生效。

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

`claude-codex-iterate.yml` 另收一个 `review_fixer`：`auto`（默认，Claude 先上，只有额度耗尽 / 限流 / 认证失效 / 服务不可用才换 Codex）、`claude`（现有行为，永不换人）、`codex`（跳过 Claude）。**拼错直接红**，不会静默按 `auto` 跑掉一整轮。测试没修好、构建挂了这类业务失败**不换人**：换个模型一样挂，job 该红就红。谁上、有没有换人、为什么，三件事都写在那次 run 的 summary 里。换人成功的那一轮照样记轮数、照样召唤复审，链条不会停在这里；令牌失效这种不会自己恢复的原因，即使换人成功也推一条通知。

`claude-codex-iterate.yml` 还收一个 `verify_writable_paths`：允许验证命令重写哪些被跟踪的文件，一行一个、精确路径、**默认一个都不许**。Codex 接管那条路里，验证命令来自被审的那个 PR，它跑完还要补一次 `git add -u`（否则推出去的是一棵没验过的树），于是它改过的被跟踪文件会跟着修复一起提交推送 —— 外部 PR 借此就能把复审机器人从没产出过的改动发布进仓库。验证会重新生成 lock 文件的仓库（`python` 的 `uv sync --dev` 重写 `uv.lock`、`node` 的 `npm ci` 重写 `package-lock.json`）**必须在调用桩里列出来**，否则那一轮红着停下，错误信息里就是被改的路径。这份清单只从调用方默认分支上的工作流文件读，被审 PR 改不到它 —— 改成从 PR 内容里读，白名单就等于攻击者自己签发的通行证。

## 测试

测试放 `tests/*.bats`（bats-core）。本地跑：`brew install bats-core && bats tests/`。

`tests/test_helper/common.bash` 带一套假 GitHub：假的 `gh` / `curl` / `sleep` / `date` 按剧本回放 API 响应并记下每次调用，测试直接执行 workflow 里抠出来的真 run 块。`tests/fixtures/` 里的 Codex 评论和 429 执行记录来自真实 run。本仓库自己的 CI 跑的是 PR 里的 `ci.yml`，所以 PR 自带的 bats 会在 PR 上跑。

`shell` runtime 的测试步骤是「有 `tests/*.bats` 就跑 bats，没有就跳过」——只有脚本、没写过测试的仓库行为不变。测试不复制一份 `ci.yml` 的逻辑，而是直接把 `Resolve commands` 那段 run 块抠出来执行；复制的那份迟早和真身各改各的。

## 密钥

五个，都在各仓库的 Settings → Secrets 里，由 `onboard.sh` 从 `~/.config/gh-workflows/secrets.env` 刷进去。**`secrets.env.example` 是那个文件的模板** —— 键名、各自干什么、去哪生成都在里面；真值只留在 `~/.config` 下（本仓库是 public，值放进仓库就等于公开）。

| 密钥 | 缺了会怎样 |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude 修复和 Claude 代审都不跑（`claude setup-token` 生成，`sk-ant-oat01-` 开头）。和本人的订阅共用每周额度 |
| `CODEX_TRIGGER_TOKEN` | 无法召唤 Codex 复审；Claude 代审结论发不出（告警 `pat-missing`）；巡检不能动手 |
| `CODEX_API_KEY` | Claude 撞额度时换不了人，`review_fixer: codex` 也跑不了（platform.openai.com 建的 API key，不是 ChatGPT 订阅） |
| `PUSHOVER_TOKEN` / `PUSHOVER_USER` | 流水线断了不会推手机通知 |

`CODEX_TRIGGER_TOKEN` 必须是真人账号建的 fine-grained PAT（GitHub Actions 自带的 bot token 发 `@codex review` 会被 Codex 拒绝）。权限选 **All repositories** + Metadata read + Issues/PR read & write —— 覆盖全部仓库，接新仓库不用回去改 PAT。

`SWEEP_READ_TOKEN` 只存在本仓库（`gh secret set SWEEP_READ_TOKEN --repo Melodymaifafa/gh-workflows`，不走 `onboard.sh`）：另建一个 fine-grained PAT，**All repositories** + Metadata read + Contents read，巡检只用它读各仓库调用桩的 `base_branch`。不把 Contents 读权限加给 `CODEX_TRIGGER_TOKEN`，因为那个令牌会复制到每个仓库，任何一个仓库泄露就能读到所有私有仓库的代码。没设它，私有仓库的调用桩读不到，巡检退回只扫默认分支是 develop 的仓库，并在 run 里警告。

## 本仓库自己也接了（2026-07-30）

在这之前，这个仓库给 7 个仓库做自动化，自己一次 run 都没跑过 —— 而它是改动风险最高的一个：一处改错，7 个仓库同时停摆。

调用桩放在 `.github/workflows/self-*.yml`。**必须换个文件名** —— 定义文件已经占了 `ci.yml` 那四个名字，同名会把定义覆盖掉（试过一次，当场翻车）。

**自动合入是安全的，因为各仓库钉的是 `@v1`。** 合进 develop / main 不改变任何仓库的行为，只有手动移 `v1` 标签才生效 —— 那一步就是真正的闸门，而它一直在人手里。

## 版本

各仓库的调用桩固定引用 `@v1`。改完这里的逻辑后要移动 tag 才会生效：

```
git tag -f v1 && git push -f origin v1
```

回退到 Claude 兜底之前的版本：`git tag -f v1 34645cf && git push -f origin v1`。

## 踩过的坑

- **顶层 `concurrency` 只能声明一次**：调用桩和被调用的可复用工作流若都在顶层声明同名 group，GitHub 判定「top level workflow」与该 job 死锁，run 立刻失败、零 job、无日志，只有一句 "This run likely failed because of a workflow file issue"。排队逻辑写在被调用方的 **job 层**，调用桩不要写 `concurrency`。`claude-codex-iterate` 踩了这个坑，2026-07-29 起 9 个仓库共 11 次触发全部空跑，直到 2026-08-20 才发现 —— 整条 Codex→Claude 迭代链从来没运行过。
- **Codex 沙箱没网、`.git` 只读**：`codex exec` 在 `:workspace` 档下改得动工作区文件，但连不上网，也写不了 `.git`（MEL-197 实测，带对照组）。所以 Codex 接管那条路里，取评论、装依赖、跑验证、commit/push、发评论全部由外层 step 做，Codex 只负责改文件和写总结 —— 把给 Claude 的那套 prompt 照搬过去必炸。
- **actionlint 内置的 action 输入清单会过期**：它报 `openai/codex-action@v1` 没有 `permission-profile` / `allow-bot-users`，实际 v1 tag 有。这类「工具数据旧了、事实是对的」的例外写在 `.github/actionlint.yaml`，每条都附核对依据；不写理由的忽略规则没人敢删，迟早掩盖真错。
- **不要放宽 `--allowedTools`**：Codex 的 review 正文是外部输入，直接进 Claude 的 prompt，而那个 token 有写权限。只放行具体命令，别用 `Bash(git:*)`。
- **`--allowedTools` 是全量清单**：`Edit,MultiEdit,Write` 不列出来 Claude 就改不了任何文件，只会干烧轮数。
- **绿勾 ≠ 有产出**：确认 Claude 真干了活要看 PR 时间线有没有评论和 commit。`claude-codex-iterate` 现在只在「推了新提交」和「看完觉得不用改」两种结局下报绿，缺凭证、额度耗尽、令牌失效、说推了却没推一律报红 —— 之前这些全被咽成 success，douyin-grabber 的自动修复因此一次都没跑起来还天天绿（MEL-236）。红的是 iterate 这条 run，`codex-approved-merge` 按名字把它排除在合并门槛外，不会因此卡住合并。
- **step 的 `if` 不写状态函数 = GitHub 隐式补一个 `success()`**：前面任何一步红了，后面所有这类 step 全被跳过，日志里只是安静的灰色。`claude-codex-iterate` 的 `Check the fix outcome` 当初只判 `gate.run`，`review_fixer: codex` 时它照跑、读到空结果就打红，Codex 接管那四步于是一次都没跑过，summary 还写着 `ran: codex`（MEL-250）。抽单个 `run:` 块的 bats 测试看不见这一层 —— 断言那一格的输出可以全绿，而那之后的每一步都被跳过；要守这条得按门禁语义重放整条 step 链（`tests/test_helper/step_gate.bash`）。
- **`git add -A` 放在验证之前，验证改的被跟踪文件会被静默丢掉**：先 add 是对的（验证会造出 `.venv` / `node_modules` / `__pycache__`，后 add 就一起提交了），但 `uv sync --dev` 默认重写 `uv.lock`、`npm ci` 重写 `package-lock.json`，这些差异不在暂存区里，commit 推出去的是一棵从没被测过的树。验证通过后补一次 `git add -u`：它只更新已经在索引里的路径，垃圾目录从没进过索引，照样进不来（MEL-252）。
- **验证跑完补的那次 `git add -u`，是外部 PR 的一条发布通道**：它把验证改过的**任何**被跟踪文件一起入索引，下一步带着写权限凭据提交推送 —— 验证命令往一个源文件里写一行，就借这条工作流的手发布了「复审机器人从没产出过的改动」。不能靠「一律拒绝验证后的改动」来堵：`uv sync --dev` 重写 `uv.lock` 是合法的，拒掉等于推翻上一条（提交验过的那棵树）。分法是白名单：验证**前后**各用一份 `mktemp` 出来的临时索引算一次 `add -u` + `write-tree`，两棵树不等就把 `git diff --name-only` 的路径逐条比 `verify_writable_paths`，有一条不在上面就红着停下，停在凭据塞回去之前。比树而不是比「`add -u` 会带进来哪些文件」：验证命令自己跑一条 `git add` 就能把新文件直接塞进真索引，那时候连 `add -u` 都不需要了。临时索引每次现开、结果只存在当前 shell 的变量里 —— 存成文件验证命令就改得动（MEL-258）。
- **跑被审 PR 自带的验证命令时，环境里不能有写权限凭据**：`npm ci` 的生命周期钩子、pytest 插件、bats 脚本都能执行任意命令，外部 PR 借此就能读走 `GH_TOKEN` 和 `actions/checkout` 持久化在 `.git/config` 里的凭证，拿到仓库写权限。**`env -u GH_TOKEN` 不算修好**：令牌还挂在 step 级 `env:` 上，父 shell 那份环境原样在，`ubuntu-latest` 上验证命令跟父 shell 同一个用户，`/proc/$PPID/environ` 读得回来。验证必须自成一步，而那一步的 `env:` 里根本没有令牌；`.git/config` 里的凭证验证前摘掉、跑完还回来，留给下一步 push。对应的测试也要断在「step 的 `env:` 声明」上 —— 只探子进程自己的 `${GH_TOKEN:-}` 的测试，对这种假修是绿的（MEL-252）。
- **`GITHUB_ENV` / `GITHUB_PATH` 是同一个洞的另一半**：验证子进程照样继承它们，往 `GITHUB_PATH` 追一个自带假 `gh` 的目录，后面「召唤复审」那步就会跑那个假 `gh` —— 而那步带的是 `CODEX_TRIGGER_TOKEN`。两道都要：子进程先拿到一组废纸篓文件，验证跑完再把真文件清空。少了后一道，它从 `/proc/$PPID/environ` 捞回真路径就直接写进去了；runner 在 step 收尾时才读这两个文件，最后写的是我们，所以清空有效。它们每个 step 一份，清空只丢本步自己写的东西（MEL-252）。
- **把令牌挪走不等于关上门：验证命令能往 `.git` 里种「下一步替它跑」的东西**。它对工作副本有写权限，于是可以写 `.git/hooks/pre-commit`（或 `commit-msg` / `pre-push` / `post-commit`），也可以往 `.git/config` 写 `core.hooksPath` 把钩子指到别处；下一步 `Commit and push` 会把 checkout 凭据塞回 `.git/config`、挂上 `GH_TOKEN`，然后 `git commit` 就替它跑了 —— 同时拿到两把写权限钥匙，而整条链 exit 0、push 正常、没有任何东西变红。**别只堵钩子**：`.git/config` 里会去跑命令的键还有 `credential.helper`（`!` 开头就是 shell）、`core.pager`、`gpg.program`、`filter.*.clean` / `.smudge`、`core.fsmonitor`，逐条列出来堵等于把「跟着复审意见一条条追」换个地方重演。两道：带凭据的 `git commit` / `git push` 加 `-c core.hooksPath=<$RUNNER_TEMP 下的空目录>`（命令行 `-c` 压得过任何配置文件里的同名键，种钩子和种 `core.hooksPath` 一起失效；`--no-verify` 挡不住 `post-commit`，别只靠它）；再给 `.git/config` + `.git/hooks` 做验证前后的指纹比对，一有差异就 `::error::` 非零退出。**比对必须排在「把凭据塞回去」之前** —— 凭据一回到 `.git/config`，种下的东西就有人替它跑了。指纹别拿 `git` 去算：要比对的正是 git 的配置（MEL-253）。
- **指纹拍的是仓库自己那份 `.git`，钥匙还能从旁边那扇门走**：验证命令改**机器上**的全局 / 系统 git 配置（`$HOME/.gitconfig`）不进指纹，指纹照样绿 —— 而全局配置里 `url.<base>.insteadOf` 配 `ext::` 传输、`credential.helper`、`gpg.program`、`core.fsmonitor`、`filter.*.clean` 每一个都会让 git 去跑一条外部命令，实测一条 `insteadOf` 就从带凭据的 `git push` 上把 `GH_TOKEN` 和 `extraheader` 一起捞走了。**别把全局配置也纳入指纹**：调用方仓库的测试套件顺手动一下全局 git 配置就整轮变红，19 个仓库一起收紧。按作用域关：验证之后每一条 git 都带 `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_SYSTEM` 指向 `/dev/null`（全局 + 系统一起作废，不用列键名；为什么是 `/dev/null` 而不是一个空文件，见下一条）。代价是 `actions/checkout` 写在全局配置里的 `safe.directory` 跟着丢掉，自托管 / 容器 runner 上会炸，所以那一项在命令行上显式补回来 —— 需要哪一项我们自己给，别的一律不继承（MEL-253）。

- **我们自己给 git 备的那份「空设置」，别落成验证命令改得动的文件**：`GIT_CONFIG_GLOBAL` 指向一个 `mktemp` 出来的空文件听着安全，可那文件在 `$RUNNER_TEMP` 下、在验证命令跑之前就建好、名字前缀还固定 —— 验证命令一个 `for f in "$RUNNER_TEMP"/no-gitconfig-*` 就把它改写成自己的 `core.fsmonitor`，而仓库 `.git` 一个字没动、指纹照样通过，接着「凭据塞回去之后」那次 `git add -u` 就替它跑了；那一刻指纹已经过去，它再往仓库自己那份 `.git/config` 写一个 `core.fsmonitor`，下一步带凭据的 `git commit` 连 `GH_TOKEN` 一起交出去。**空配置用 `/dev/null`**：永远读得到、永远是空的、它改不了。空钩子目录只能是真目录，所以仍然 `mktemp -d`，但**验证命令跑完、进程组收干净之后再换一个新的** —— 旧那个它看得见，往里丢一个 `post-index-change` 同样会被那次 `add -u` 执行（MEL-256）。

- **`.git/config` 的指纹要认「还是不是原来那个文件」，不能只认内容**：`sha256 <"$git_dir/config"` 跟着快捷方式走。验证命令把此刻还没凭据的 `.git/config` 复制到仓库里一个**已被跟踪**的文件、再把 `.git/config` 换成指向它的 symlink，内容一字不差、指纹通过；凭据塞回去时 git 顺着 symlink 写进了那个被跟踪的文件（`git config` 写之前会 resolve symlink 再 rename），紧接着的 `add -u` 把它入索引，下一步提交推送 —— **凭据明文进了 PR 的提交**。照钩子那一半已经写好的样子来：先判 `-L`，不是普通文件就红着停下（停在凭据塞回去之前），并把 inode / 权限位 / 链接数一起记进指纹（MEL-256）。
- **验证跑完还要确认它没留下活着的进程**：验证命令可以 fork 一个进程再让自己退出，指纹和废纸篓文件都不杀进程 —— 那个进程活到「凭据塞回 `.git/config`」和下一步导出 `GH_TOKEN` 的时候，同一个用户，轮询就能把钥匙捞走。`set -m` 让验证命令自成一个进程组（组号 = 该任务的 pid），跑完 `kill -- -组号` 整组收掉，TERM 扛得住的（`trap '' TERM`）再 KILL，**收干净之前不许把凭据塞回去**。`ps` 用不了就红着停下：这一道要是静默 no-op，比没有更糟（MEL-253）。
- **按进程组收尾挡不住一句 `setsid`**：验证命令起后台任务时加一句 `setsid`（或者自己来一次双重 fork），后代就换到新的会话、新的进程组，按组号去 `ps` 的收尾压根看不见它。它活到「凭据塞回 `.git/config`」那一刻就把钥匙抄走；更狠的是等指纹和白名单都判完之后再改一个源文件、自己 `git add`，下一步就替它提交推送 —— 前面那些判定一个都不作数了。**两道**：① 凭据摘掉之后**不再还回** `.git/config`，带凭据那一步自己用手上的 `GH_TOKEN` 现造一份（`actions/checkout` 写进去的就是 `AUTHORIZATION: basic base64(x-access-token:<token>)`），通过 `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_0` / `GIT_CONFIG_VALUE_0` 只递给那一条 `git push` —— 不落文件（落了就有人轮询）、不上命令行（`argv` 在 `/proc` 里公开）；② 「那一棵进程树死透了」要有**正面证据**，而证据不能建立在任何一样「它自己交得出去的东西」上。**继承的描述符不算**：工作流源码在 PR 里公开可见、描述符号写死在里面，验证命令开头一句 `exec 8>&-` 再 `setsid` 躲起来，我们这头立刻读到 EOF、判定「死透了」，而它还活着（Codex 2026-09-25 挂的 P1，审核方独立实跑复现）。进程组、会话、描述符它都能主动丢掉；丢不掉的只有**运行用户** —— 它没有提权手段，`fork` / `exec` / `setsid` 出来的每一个进程都还挂在同一个 uid 上，而「同一个 uid」正好就是它能读走凭据的那个条件。所以按 uid 正面清点：验证之前拍一份「这个用户当下有哪些进程」（身份 = pid + 启动时刻，只活在父 shell 的变量里，落文件它就改得动），跑完反复清点，直到某一刻这个用户名下除了基线里那些和我们自己的后代之外一个都不剩 —— 那一刻就是证据（真有哪一刻空了它就再也回不来，没有任何进程能把它拉起来）。5 秒内一直不空就红着停下，**不杀**：分不清那是逃逸的后代还是机器上别人的进程，误杀比红着停下糟。代价是本机跑测试时机器上别的长命进程刚好在这一瞬起来也会被记一笔（runner 上进程表干净，不会）—— 测试里靠「报出来的 pid 不是我们种的那个就重跑一遍」区分，重跑不会放过真逃逸（MEL-255）。
- **「凭据在 step 的 `env:` 里」不是靠挪位置能修好的**：Linux 上同一个 uid 的活进程从 `/proc/<pid>/environ` 就把它读回去了，放文件更糟（谁都能轮询），上命令行也一样（`argv` 公开），`unset` 改不掉 `/proc` 里那份初始环境。上一轮的验收记录写成「躲开之后它找不到任何可轮询的凭据」，这句话是错的 —— 凭据只是从文件挪进了进程环境。正确的说法是**不许有人等**：每个 step 是各自一个进程，验证那一步早已退出（死进程没有 environ），带凭据那一步在验证跑的时候还不存在，所以唯一的风险就是「验证留下了活进程」，上一条那道清点把它堵掉、清不干净就红着停下，带凭据那一步压根不会开始。想让 environ 连同一个用户也读不到，只有把验证命令换到另一个用户 / 容器里跑：代价是它的 `$HOME`、缓存、工作区归属全变，19 个调用方仓库的验证命令要一起适配，本轮没做（MEL-255）。
- **PATH 前几项在 `$HOME` 下，验证命令写得动 —— 它能换掉我们后面要跑的命令本身**：`ubuntu-latest` 的 PATH 第一项就是 `/home/runner/.local/bin`（还有 `.cargo/bin`、`.dotnet/tools` 之类），验证命令跟我们同一个用户，往那儿放一个假 `ps` 就把自己从清点里隐掉、放一个假 `git` 就报一棵假的树、放一个假 `gh` 就在下一步直接拿到令牌 —— 指纹、白名单、清点全部变成空转，而 `.git` 一个字没动。**两步（验证、带凭据那一步）各自把 PATH 过滤成「我们写不动的目录」**：目录本身不可写还不够，上一级可写就能把整个目录换掉，所以连父目录一起看；原来那份 PATH 只交给验证命令自己（它要 `uv` / `npm` / `node` 那些装在 `$HOME` 下的工具）。过滤完少了 `git` / `ps` / `awk` 就红着停下 —— 这一道要是静默空转，比没有更糟。**还没覆盖到的**：「召唤复审」那一步的 `gh` 仍然走原来的 PATH，而它手上是 `CODEX_TRIGGER_TOKEN`（换 PATH 会让一大批用假 `gh` / `curl` / `date` 的测试一起重写，另开一票）（MEL-255）。
- **GitHub 托管 runner 给 `runner` 用户免密 `sudo`**：真要动它，上面这一整串（进程清点、PATH、指纹、白名单）全都绕得过去 —— 这一系列防的是「不动 sudo」的那一类验证命令，也就是 `npm ci` 的生命周期钩子、pytest 插件那种顺手就能执行任意代码的路子。别把这些防线当成「外部 PR 在 runner 上做不了坏事」（MEL-255）。
- **`git clean -fd` 清不掉被忽略的残留**：Claude 撞额度前跑一半的 `uv sync` 留下的 `.venv`、`node_modules`、build 产物都躲在 `.gitignore` 后面，没有 `-x` 就原地留着跟进 Codex 那一轮，验证于是跑在一个被污染的工作区上。换人前的清理一律 `git clean -fdx`；本轮要留的东西（预取的 review 正文）在 clean 之前挪出工作区、clean 之后再放回来（MEL-252）。
- **`.git/info/exclude` 挡不住 `git reset --hard`**：exclude 只管 `git add` 和 `git clean` 不去碰**未跟踪**的文件；调用方仓库自己跟踪了同名文件时，`reset --hard` 照样把它恢复回来，把写在那儿的预取内容盖掉。工作区里放「只给这一轮用」的文件，要么放到工作区外，要么带上 run id（同「取脚本的落点必须带 run id」那条），别指望 exclude（MEL-252）。
- **关键那一步要排在前面，别排在发评论后面**：同上一条的门禁语义，`gh pr comment` 偶发失败一次，排在它后面的步骤就整个被跳过。`claude-codex-iterate` 里「召唤复审」一度排在「发总结评论」之后 —— 总结那步一抖，Codex 刚推的提交就没人复看，链条静默停住。链条上必须发生的事排前面，给人看的排后面（MEL-252）。
- **`@codex review` 会被限流静默**：连发几次后连 👀 都不回，约 10 分钟恢复。现在 iterate 只召唤一次，沉默由 watcher 的 5 分钟兜底接手。
- **Codex 额度用完时它照样回一条评论**：旧版超时告警把它当成「Codex 有反应」，于是既不告警也不合并，PR 就这么卡住（2026-09-17，3 个 PR）。现在认出这句话就当场换 Claude。
- **秒合并的 PR** 会让 Codex 迟到的 review 落在已关闭的 PR 上，job 被跳过是正常现象。
- **密钥只写不读，个人账号也没有账号级密钥**：存进仓库后连 API 都取不回值（`gh api repos/X/actions/secrets/NAME` 只返回名字和日期），共享密钥是 organization 才有的功能。所以 `secrets.env` 是唯一母本 —— 在网页上手填过的值必须补回母本，否则接新仓库时无处可取（2026-07-30 为此翻了半天 `~/.claude/history.jsonl`）。
- **Regenerate PAT 会立刻作废旧值**：换完要把所有仓库的 secret 一起刷新。漏掉的那个 CI 照样绿，只有 Codex 复审那步静默停住。
- **bats 里别直接写 `[[ ... ]]`**：中途失败的 `[[ ]]` bats 抓不住，只认最后一条命令的退出码，测试于是假绿（一条明知会挂的断言照样报 ok）。用 `tests/test_helper/common.bash` 里的 `assert_equal` / `assert_contains`，函数返回非零它抓得住。
- **接完要把仓库默认分支改成 `develop`**：`onboard.sh` 起手要求默认分支是 `main`（它靠 main 建 develop），但完成后会自动改成 `develop`。如果这步失败，必须手动补；否则 `gh pr create` 不带 `--base` 会打向默认分支。linear-agent-team 忘了改，agent 开的 3 个 PR 全合进 main，develop 停在初始 commit（2026-07-30）。
