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
| `claude-codex-iterate.yml` | Codex 或 Claude 代审提交意见后 | 选一个 fixer 读意见、只改代码；验证、push、发中文总结由不带凭据/带凭据的独立步骤接手，然后召唤复审；最多连修 5 轮，修满还有意见就让 Claude 逐条判断剩下的意见拦不拦合并（见下方「修满轮数之后」）。默认 Claude 先上，撞额度/限流/认证失效才换 Codex 接手 |
| `codex-approved-merge.yml` | PR 开启 / 有人喊 `@codex review` / Claude 代审通过 / 修满轮数后 Claude 判定剩下的意见不拦合并 | 先等 Codex；Codex 不行就换 Claude 代审这一次。审核无意见 + CI 全绿，自动 squash 合入调用桩 `base_branch` 指定的分支（默认 develop） |
| `pr-sweeper.yml` | 定时（cron 写每 15 分钟，实测 2–7 小时一次；只在本仓库跑） | 扫 owner 名下所有仓库，集成分支取各仓库调用桩的 `base_branch`；给没人管的 PR 重新叫审、重修，卡住就推一次手机通知 |
| `ff-main.yml` | 每月 1 / 15 号 09:00，也可手动点 | 把 main 快进到 develop 上「泡够 7 天」的那个位置。CI 不全绿就跳过并推手机通知；分叉了直接拒绝 |

## 审核：Codex 优先，Claude 兜底（2026-09-18）

每一次审核请求都先问 Codex。出现下面任一情况，**这一次**改由 Claude 只读代审，结果由 owner 的 PAT 发出（这样下一环才会被触发）：

- Codex 回复「reached your Codex usage limits」（30 秒内发现）；
- 喊了 `@codex review` 5 分钟没有 👀 也没有结论；
- 20 分钟还没有结论。

没有「Codex 已坏」的全局开关：下一轮照样先问 Codex，它额度恢复就自动接回。Claude 代审只读（Read/Glob/Grep），看不到任何密钥，结论必须是合法 JSON 才算数；空结果一律当「没审过」，绝不当「通过」。**有意见的 head 不会被合并**，唯一的例外是下面「修满轮数之后」那条路：Claude 逐条核过、点名放过的那几条意见。

机器之间靠藏在评论里的标记接力，只认 `github-actions[bot]` 或 OWNER 写的，`claude[bot]` 写什么都不算：

| 标记 | 谁写 | 意思 |
|---|---|---|
| `codex-review-head: H` | PAT（iterate / 巡检） | 请审 H；可带 `fix-round: N` 或 `pr-sweeper: kick` |
| `pr-guard: fallback head=H` | GITHUB_TOKEN | Codex 这次不行，换 Claude |
| `claude-review-findings: H` | PAT | Claude 代审有意见（一条 COMMENT review） |
| `claude-review-clean: H` | PAT | Claude 代审无意见，CI 绿就合 |
| `claude-judge-clean: head=H reviews=ID,…` | PAT（iterate 的 round-cap-judge） | 修满轮数后 Claude 判定这几条 review 里的意见都不拦合并，CI 绿就合；之后在 H 上新出的 review 照样拦 |
| `claude-judge-fix: head=H` | PAT（iterate 的 round-cap-judge，一条 COMMENT review） | 修满轮数后 Claude 确认这几条是真 bug，接着修（第二阶段，最多到 `max_confirmed_fix_rounds` 轮） |
| `codex-fix-request: head=H round=N run=ID` | PAT（iterate） | 请 Codex 云端出一段补丁（句子里没有「@codex review」，不算复审请求） |
| `fix-retry: head=H review=ID` | PAT（巡检） | 上次修复没完成，再修一次 |
| `pr-guard: fix-round head=H round=N` | GITHUB_TOKEN | 第 N 轮修复已推送（轮数不靠召唤是否成功） |
| `pr-guard: alert head=H reason=R until=T` | 各环节 | 已告警 R，同一 head 同一原因只推一次 |

告警原因 R：`ci` `unmergeable` `merge-refused` `merge-failed` `conflict` `review-quota` `fix-quota` `auth` `pat-missing` `review-failed` `fix-failed` `no-fix` `verify-failed` `push-failed` `stale-workflow` `round-cap` `retry-exhausted` `stalled` `unwatched` `codex-no-patch` `codex-no-env` `codex-patch-rejected` `codex-no-review`。额度类（`*-quota`）撞第二次只补一条带新恢复时间的静默标记，不再推送。

### 修满轮数之后（2026-10-04）

自动修满 `max_fix_rounds`（默认 5）轮、head 上还有意见时，不再直接停下告警，而是交给 iterate 里的 `round-cap-judge` job：Claude 只读这个 head 上剩下的全部意见（每条编号 F1、F2…，判决必须每个编号恰好一条，漏一条就算没判成）、PR 改动和代码，逐条重新定级——P0 安全 / 数据 / 线上故障，P1 确实存在的 bug，P2 可选的小改进、纯风格、文档措辞或误报，拿不准按 P1。

- 全是 P2：用主人的 PAT 发一条评论，逐条写明放过了哪几条、为什么，末尾带 `claude-judge-clean` 标记，并推一次手机通知。`codex-approved-merge` 的路径 E 只放过标记里点名的那几条 review，之后在这个 head 上新出的意见照样拦；CI 全绿才合。
- 有 Claude 确认的 P0 / P1（第二阶段，2026-10-04）：不停车，用主人的 PAT 发一条 review，只列确认的那几条（带 `claude-review-findings` 和 `claude-judge-fix` 标记），iterate 收到后接着修，修完照旧请 Codex 复审、再判。一直修到 `max_confirmed_fix_rounds`（默认 10）轮；第 10 轮之后还有确认的 bug，才告警 `round-cap` 停下、推一次手机通知，告警里写明还剩哪几条。到第 10 轮剩下的全是 P2，照样合并。
- 审查方标了 P0 而 Claude 一条都不认、或者 Claude 没判成（额度、输出不合法）：不替人拿主意，直接告警 `round-cap` 停下。
- 同一个 head 只认第一个判决：已有 `round-cap` 告警，或者已有的放行标记点过它全部意见的名，就不再判；同一个 PR 的判决排队执行，发之前再查一遍。放行之后同一个 head 上又来了新意见，它没被点过名，下一轮会重判。
- 每个修满轮数的 head 一定留下一个判决：主人的 PAT 缺失或失效、judge 半路挂了，`round-cap-park` 用 job 自己的令牌照旧告警 `round-cap`；没配 PAT 时 Gate 干脆不叫 judge，直接告警。
- judge 在 iterate 红了时也跑，所以它自己再验一遍模型和思考力度（同一段 case 块，`tests/claude-model.bats` 盯着三处一字不差）。
- 放行之后没合上（多半是当时 CI 还没绿）：巡检不把点名的那几条当成没修的意见去重修，而是空闲 60 分钟后把同一条放行标记再发一次，让合并检查重跑；补 2 次还没合上就告警 `stalled`。

Claude 这一步的形状同代审：只给 Read/Glob/Grep、只读令牌、根目录是受信任的 base，主人的 PAT 只在最后发结论那一步。

### 判「不用改」之后（2026-10-06，MEL-307）

修复那一轮 Claude 看完意见判「都不用改」时，不再停车等人点 Merge，而是交给同一个 judge 逐条复核：没有真 bug 就发放行标记、CI 全绿后合并；有确认的 bug 就发 M9 接着修。放行不推手机（这是常态）。照旧停车告警 `no-fix` 的三种：没配主人的 PAT；这一轮修的正是 judge 确认的 bug（两个 Claude 意见相反，再判只会来回转）；judge 没判成或审查方标了 P0 而 Claude 不认。`judged_already` 把 `no-fix` 停车也算一个判决，同一个 head 不重判。

**以后再做的记到 Linear**：judge 给每条 P2 多填一个 `later`。`later=true`（优化、新功能、超出本 PR 范围但值得做）在放行或 M9 时记成一张 Linear 票：Backlog、不指派、带 Improvement 标签，正文写 judge 的理由、来源 PR 和原意见链接 —— 不进 Agent Queue，流水线不给自己派活。找项目先认挂着这个仓库 GitHub 链接的项目（名字常对不上，如 `learn-api-integrations` → Duolinguo learning app），再认同名项目（跳过已取消的），都没有就建一个同名项目并挂上链接。每次最多 5 张；同一个 PR 同标题的票不重记。没配 `LINEAR_API_KEY`、Linear 出错或查不到团队的 Backlog 状态（免得票落进 Triage）只写进评论（M9 时写进那条 review，注明本 PR 不用改），照样放行。停车时不记票，人先看。

改好了却没推上去时，PR 上也一定有一句话（2026-10-05）：验证命令没过 → `verify-failed`；提交了但 push 被拒 → `push-failed`，告警里直接说是哪一种拒（令牌不许改 workflow 文件 / 分支保护 / 分支落后），两条都带 run 链接。`claude-code-action` 因为「PR 分支上的调用桩跟默认分支不一样」把自己整步跳过时 → `stale-workflow`，告警直接写「点 Update branch」。这三种以前在 PR 上一个字都没有，只能等巡检重试两次之后收到一条不说原因的 `retry-exhausted`。

审查通过却没合上时，合并环节会告警而不是只让 run 变红：`merge-refused` 是机器人的令牌没权限合（PR 开出后集成分支上的 workflow 文件被改过）——把集成分支合进 PR 分支再推上来，或手动点 Merge；`merge-failed` 是其它原因被拒，日志链接在告警里，巡检之后会再试。

**巡检**（`pr-sweeper.yml` + `scripts/pr-sweep.sh`）是兜底：没人碰过的 head 空闲 30 分钟、或任何 head 空闲 60 分钟就重新叫审（每个 head 3 次、间隔 ≥ 60 分钟，之后告警 `stalled`，再每天一次共 7 天）；有意见但修复失败的 head 重修最多 2 次（撞额度的不算，但总数封顶 6 次），之后告警 `retry-exhausted`。停车的 head（`no-fix` `round-cap` `retry-exhausted` `merge-refused`、CI 红）等人处理。没人管的 PR（仓库没接共享调用桩，或 PR 没打向集成分支）空闲 60 分钟后每个 head 告警一次 `unwatched`，不叫审不重修。

- **集成分支**：每个仓库从默认分支上的 `.github/workflows/codex-approved-merge.yml` 读 `base_branch`（本仓库读 `self-codex-approved-merge.yml`），没写就是 develop。读不到（多半是 `CODEX_TRIGGER_TOKEN` 缺 Contents 权限）就按旧规则只扫默认分支是 develop 的仓库，run 里警告一次。
- **漏接的仓库每轮都点名**（2026-10-06，MEL-308）：有开着的 PR 却没装共享调用桩的仓库，run 摘要和 warning 里每次都列出来，并给出 `./onboard.sh <仓库> <python|node>`。`unwatched` 告警是按 head 去重的，head 不变就只响一次 —— 但仓库漏接是仓库级的，换个 head 也不会自己好，所以这条不跟着 head 去重。MEL-308 查出来的就是这个：三个仓库漏接，5 个 PR 全停，最久的两周没人管。
- **节奏**：cron 写的每 15 分钟，GitHub 实际 2–7 小时才跑一次，所以上面的 30 / 60 分钟只是下限。急的话手动点 **Actions → PR sweeper → Run workflow**，取消勾选 `dry_run` 才会动手。
- **开关**：本仓库的 Actions 变量 `SWEEP_MODE` = `off`（默认，没设也是 off）/ `dry`（只在 run 摘要里写「会做什么」）/ `live`。出问题先改回 `off`。
- **本仓库需要 4 个密钥**，巡检才能跑（2026-09-18 已加）；读各仓库调用桩也用其中的 `CODEX_TRIGGER_TOKEN`，不用另配。
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

`package.json` 的 `engines` 要求比 `ci.yml` 的默认 node 20 新时用 `NODE_VERSION=24 ./onboard.sh <repo> node` 钉住，否则第一次接入就装不上依赖。只有 `ci.yml` 收这个值：中央 `claude-codex-iterate.yml` 的 `setup-node` 写死 node 20 且没开成 input，所以钉了别的版本时修复那一轮仍是 20，接入时会为此打一条警告 —— 跟 `verify_cmd` 跟不上覆盖值时同一种单向代价（CI 绿着、修复那一轮红）。

**本仓库已是 public（2026-07-30），公开和私有仓库都能接。** 之前是 private 时，公开仓库调用它会失败得毫无线索：run 存在但 0 秒结束、一个 job 都没有、只报 "workflow file issue" —— 跨可见性调用不被允许，而报错完全不提这回事。顺带好处：公开仓库的 Actions 分钟数免费无上限，私有仓库每月 2000 分钟。

Codex connector 是账号级授权，新仓库无需单独授权（2026-07-29 在 learn-api-integrations 实测：新开的 PR 2 分钟内就被自动 review 并 👍）。

**接完还要手动做一件事**：到 [chatgpt.com/codex/cloud/settings/environments](https://chatgpt.com/codex/cloud/settings/environments) 给这个仓库建一个环境，默认设置即可。*review* 不需要它，Claude 撞额度时**请 Codex 出补丁**需要 —— 没建的话 Codex 只回一句「先建环境」，那一轮红着停下并告警 `codex-no-env`。

## 调用桩长什么样

`stubs/` 里三个文件就是全部。每个仓库只放这三个，逻辑全在本仓库。例如：

```yaml
jobs:
  ci:
    uses: Melodymaifafa/gh-workflows/.github/workflows/ci.yml@v1
    with:
      runtime: node
```

`runtime` 三种：`python`（`uv + ruff + pytest`）、`node`（`npm` + `npm run test --if-present`）、`shell`（`actionlint + shellcheck`，给只有 bash 脚本和 workflow YAML 的仓库用，本仓库自己就走这个）。仓库有特殊情况时可以用 `install_cmd` / `lint_cmd` / `test_cmd` 单独覆盖；传 `skip` 表示该仓库暂时没有 lint 或测试。

**修复那一轮的默认验证命令跟 `ci.yml` 的默认值逐字一样**，`tests/iterate-gate.bats` 有一条判定把两边钉在一起。差一个字的代价是单向的：没有 `package-lock.json` 的仓库 `npm ci` 直接失败，没有 `test` 脚本的仓库 `npm test` 报 Missing script —— CI 两样都绿着放过，修复那一轮却必然红（MEL-293）。`ci.yml` 用 `install_cmd` / `test_cmd` 覆盖过默认值的仓库，`claude-codex-iterate.yml` 的 `verify_cmd` 也要跟着覆盖，否则同一个坑换个地方出现。

**`onboard.sh` 会自动把这两处一起写出来（MEL-303）**：`INSTALL_CMD` / `LINT_CMD` / `TEST_CMD` 任意一个有值时，它在 iterate 调用桩里写一个三条命令的 `verify_cmd`，没覆盖的那几条用跟 `ci.yml` 逐字相同的默认值填齐 —— `verify_cmd` 是整份替换、不是逐行合并，只写被覆盖的那一条会让另两条从修复那一轮里整个消失。三条各包在一对独占一行的 `( )` 里（子 shell）：`ci.yml` 里装 / lint / 测各是一个 step，中央仓库却把整块 `verify_cmd` 当一个脚本跑，不隔开的话装依赖那条的 `cd frontend` 会带进后两条（它们自己的 `cd frontend` 当场失败），一条 `exit 0` 会让后面几条整个不跑。括号不跟命令写在同一行，是因为覆盖值末尾的 `#` 注释 `ci.yml` 照跑，同一行的右括号却会被它吃掉。`skip` 翻成 `echo "::notice::<步骤> skipped by caller"`，跟 `ci.yml` 里 `skip` 的行为（打一条 notice 然后退出 0）对齐：原样写 `skip` 会被当成命令、找不到就整轮红，写成空行则中央仓库判定「没有验证命令」拒绝推送。三条全 `skip` 的仓库接入时会收到一条警告 —— 那种仓库的修复不经任何检查就推上 PR（CI 本来也一条都不跑，所以不是新开的洞，但只有接入那一刻说得出口）。手改 `ci.yml` 的覆盖值时记得一起改 `verify_cmd`，`tests/onboard-verify-cmd.bats` 把 `onboard.sh` 填的默认值和 `ci.yml` 的钉在一起。

`claude-codex-iterate.yml` 另收一个 `review_fixer`：`auto`（默认，Claude 先上，只有额度耗尽 / 限流 / 认证失效 / 服务不可用才换 Codex）、`claude`（现有行为，永不换人）、`codex`（跳过 Claude）。**拼错直接红**，不会静默按 `auto` 跑掉一整轮。测试没修好、构建挂了这类业务失败**不换人**：换个模型一样挂，job 该红就红。谁上、有没有换人、为什么，三件事都写在那次 run 的 summary 里。换人成功的那一轮照样记轮数、照样召唤复审，链条不会停在这里；令牌失效这种不会自己恢复的原因，即使换人成功也推一条通知。

**Codex 接手不跑在 runner 上，也不要 OpenAI 的 API key（2026-10-02）。** 流水线用主人的 PAT 在 PR 上留一句写死的话（`@codex fix … paste the complete change as one unified diff …`），等 `chatgpt-codex-connector[bot]` 回复，取出回复里**恰好一个** diff 代码块、`git apply` 打到工作区，之后的验证 / 推送 / 召唤复审原样复用。Codex 走的是主人自己的 ChatGPT 订阅，所以**每个仓库都要在 [chatgpt.com/codex/cloud/settings/environments](https://chatgpt.com/codex/cloud/settings/environments) 建一个环境**（默认设置即可），没建它只回一句「先建环境」。下面任一情况这一轮红着停下、发一次告警、什么都不推（巡检之后会再叫 Claude）：15 分钟没回（`codex-no-patch`）、回的是「先建环境」（`codex-no-env`）、额度 / 限流提示、没有 diff 块、贴了两段、回复被截断、补丁打不上或碰到 `.github/workflows/`（`codex-patch-rejected`）。**只有 Codex 自己写的 review 走这条路**：Claude 代审写的意见里没有「your review」的指代对象，那种轮次直接红（`codex-no-review`）。

`claude-codex-iterate.yml` 和 `codex-approved-merge.yml` 都收 `claude_model`（默认 `claude-opus-5-5`）和 `claude_effort`（默认 `xhigh`）。**默认值永远钉死，永远是 Opus 及以上**：不钉，action 就用 Claude Code 的账号默认模型 —— 2026-09 之前那是 Sonnet，静静跑了几周没人发现（PR #17 两轮修复都是它做的）。只认明确写出的 Opus 及以上（`opus` / `fable` 别名或 `claude-opus-*` 这类 id）；Sonnet、Haiku、`default`、`opusplan` 整轮直接红。Opus 5.5 自带的思考力度是 medium，所以钉 xhigh。每条 Claude 总结评论末尾写出实际跑的模型名（从 SDK 执行记录里读，不是配置里抄的）—— 哪天默认值悄悄变了，PR 上一眼看得到。换新模型：改这两个默认值 → 合入 → 移 `v1` 标签。

`claude-codex-iterate.yml` 还收一个 `verify_writable_paths`：允许验证命令重写哪些被跟踪的文件，一行一个、精确路径、**默认一个都不许**。**两条路都归它管**（Claude 那条从 MEL-254 起也走同一个验证步骤）：验证命令来自被审的那个 PR，它跑完还要补一次 `git add -u`（否则推出去的是一棵没验过的树），于是它改过的被跟踪文件会跟着修复一起提交推送 —— 外部 PR 借此就能把复审机器人从没产出过的改动发布进仓库。验证会重新生成 lock 文件的仓库（`python` 的 `uv sync --dev` 重写 `uv.lock`、`node` 的 `npm ci` 重写 `package-lock.json`）**必须在调用桩里列出来**，否则那一轮红着停下，错误信息里就是被改的路径。这份清单只从调用方默认分支上的工作流文件读，被审 PR 改不到它 —— 改成从 PR 内容里读，白名单就等于攻击者自己签发的通行证。

还收一个 `verify_isolation`（`auto` / `off`，默认 `auto`）：验证那一步把被审 PR 自己的命令换到一个专用的无权限账号（`ghwf-verify`，用到才建）下跑。它跟我们不是同一个用户，内核就不让它读我们这一步的 `/proc/<pid>/environ` —— 而那份进程环境是写权限令牌唯一的落点（见下方「凭据在 step 的 `env:` 里」）。顺带两类一起没了：它名下没有服务管理器（`systemd-run --user` / `crontab` 那种「请别人代跑」），它也不在 sudoers 里。代价是 `$HOME`、缓存、临时目录全换成 `$RUNNER_TEMP` 下的沙箱，**缓存是冷的**（`uv` / `npm` 第一轮重新下载）；指向 runner 那个用户私有目录的环境变量（`UV_CACHE_DIR`、`XDG_*`）启动时改指沙箱，漏一个的长相是「权限不够」当场失败，不是静默写进我们的目录。「此刻名下没人」不等于「过后没人来」（cron 的守护进程每分钟自己看一遍用户的 crontab，不需要服务管理器），所以两头都收：账号一建好就写进 `/etc/cron.deny` 和 `/etc/at.deny`，验证跑完、清点通过之后立刻把它从工作区那个组里摘出去 —— 之后排起来的任务既走不进去也写不动那棵树。清点那个账号名下有没有活进程用 root 的身份去问（`procfs` 配了 `hidepid` 的机器上普通身份看不见别人的进程，而「看不见」就是这道清点的放行条件），跑验证之前还先在那个账号下起一个短命进程、确认清点真看得见它。「这台机器证不出已经隔离」的每一种（没有免密 `sudo`、找不到绝对路径的 `bash`、工作区那个组本身带权限、`ghwf-verify` 跑之前机器上就已经有了而不是这一次 run 建的、它原本还在别的组里、两份拒绝名单写不进去、清点看不见那个账号）都自己回退到原来那条路并刷一条 warning —— 这一步 fail closed 等于 19 个仓库一起推不出修复。「是不是这一次 run 里我们自己建的」认的是 root 写在 `/run/ghwf-verify/` 下、文件名带 run 号和重跑次数的那份标记（目录 `0700 root:root`，那个账号写不动、伪造不了）：捡一个机器上本来就有的账号来跑，等于把它身上已经排好的 `crontab` / `at` 任务、`cron.allow` 里的名字、linger 起来的用户定时器一整类都接过来，而那些逐条清永远清不全。**代价**：持久的自建 runner 上账号留在机器上、标记每一次 run 换一个文件名，所以从第二次 run 起都走原路径；今天全是 GitHub 的一次性机器，账号每次现建，碰不到。哪个仓库的验证命令真离不开 runner 用户的 `$HOME` 或工作区归属，调用桩里写 `verify_isolation: off`。

## 测试

测试放 `tests/*.bats`（bats-core）。本地跑：`brew install bats-core && bats tests/`。

`tests/test_helper/common.bash` 带一套假 GitHub：假的 `gh` / `curl` / `sleep` / `date` 按剧本回放 API 响应并记下每次调用，测试直接执行 workflow 里抠出来的真 run 块。`tests/fixtures/` 里的 Codex 评论和 429 执行记录来自真实 run。本仓库自己的 CI 跑的是 PR 里的 `ci.yml`，所以 PR 自带的 bats 会在 PR 上跑。

`shell` runtime 的测试步骤是「有 `tests/*.bats` 就跑 bats，没有就跳过」——只有脚本、没写过测试的仓库行为不变。测试不复制一份 `ci.yml` 的逻辑，而是直接把 `Resolve commands` 那段 run 块抠出来执行；复制的那份迟早和真身各改各的。

## 密钥

五个，都在各仓库的 Settings → Secrets 里，由 `onboard.sh` 从 `~/.config/gh-workflows/secrets.env` 刷进去。**`secrets.env.example` 是那个文件的模板** —— 键名、各自干什么、去哪生成都在里面；真值只留在 `~/.config` 下（本仓库是 public，值放进仓库就等于公开）。

| 密钥 | 缺了会怎样 |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude 修复和 Claude 代审都不跑（`claude setup-token` 生成，`sk-ant-oat01-` 开头）。和本人的订阅共用每周额度 |
| `CODEX_TRIGGER_TOKEN` | 无法召唤 Codex 复审；Claude 撞额度时请不动 Codex 出补丁；Claude 代审结论发不出（告警 `pat-missing`）；巡检不能动手 |
| `PUSHOVER_TOKEN` / `PUSHOVER_USER` | 流水线断了不会推手机通知 |
| `LINEAR_API_KEY` | judge 判为「以后再做」的意见不记 Linear 票，只写在 PR 评论里；照样合并（Linear 个人 API key，`lin_api_` 开头） |

`CODEX_TRIGGER_TOKEN` 必须是真人账号建的 fine-grained PAT（GitHub Actions 自带的 bot token 发 `@codex review` 会被 Codex 拒绝）。权限选 **All repositories** + Metadata read + Issues/PR read & write + **Actions read & write** + **Contents、Workflows read & write** —— 覆盖全部仓库，接新仓库不用回去改 PAT。Actions 写权限只用在一处：机器人推的修复提交，它的 CI 在有的仓库会被 GitHub 扣成「等人批准」（`action_required`），召唤复审那一步用这把令牌批掉**本轮自己刚推的那个提交**上被扣的 run，别的不碰；没这个权限只 warning，CI 照旧等人点（MEL-292）。Contents、Workflows 写权限是为本仓库把它复用成 `SELF_WORKFLOWS_TOKEN`（见下一段）；巡检读各仓库调用桩也顺带用它的 Contents 权限。代价：每个仓库都存着它，任何一个泄露，别人就能改所有仓库的代码和流水线 —— 2026-10-06 认了这个代价，换「不用再管第二把令牌」。

`SELF_WORKFLOWS_TOKEN` 只设在本仓库，值就是 `CODEX_TRIGGER_TOKEN` 那一把，不另建（2026-10-06）：`set -a && source ~/.config/gh-workflows/secrets.env && set +a && printf %s "$CODEX_TRIGGER_TOKEN" | gh secret set SELF_WORKFLOWS_TOKEN --repo Melodymaifafa/gh-workflows`。`onboard.sh` 不刷它 —— 代码只在本仓库读这个名字。GitHub 不许没有 Workflows 权限的令牌推、合 `.github/workflows/` 下的改动，而本仓库的 PR 几乎都改这些文件（2026-09-26 到 10-01，17 / 18 / 19 号 PR 为此停了 5 次里的 4 次）。只交给两处：iterate 推修复那一条 `git push`、codex-approved-merge 那一条 `gh pr merge`；验证命令、跑被审 PR 代码的步骤、Claude / Codex 那几步都拿不到，同一步里的 `gh pr comment` 也照旧用 `github.token`。没设它行为不变 —— 照旧走 `github.token`，推不动 / 合不动就按现有告警走（MEL-295）。

`SWEEP_READ_TOKEN` 不用了（2026-10-06）：`CODEX_TRIGGER_TOKEN` 有了 Contents 权限，巡检直接拿它读各仓库调用桩的 `base_branch`，代码也不再读这个名字 —— 留着一把过期的单独令牌，反而会顶掉能用的那把、让私有仓库的调用桩读不到。以前设过的删掉即可：`gh secret delete SWEEP_READ_TOKEN --repo Melodymaifafa/gh-workflows`，那把 PAT 也可以在 GitHub 上作废。

## 本仓库自己也接了（2026-07-30）

在这之前，这个仓库给 7 个仓库做自动化，自己一次 run 都没跑过 —— 而它是改动风险最高的一个：一处改错，7 个仓库同时停摆。

调用桩放在 `.github/workflows/self-*.yml`。**必须换个文件名** —— 定义文件已经占了 `ci.yml` 那四个名字，同名会把定义覆盖掉（试过一次，当场翻车）。

**自动合入是安全的，因为各仓库钉的是 `@v1`。** 合进 develop / main 不改变任何仓库的行为，只有手动移 `v1` 标签才生效 —— 那一步就是真正的闸门，而它一直在人手里。

## 有新 Opus 了提醒一声（2026-10-04）

`opus-model-probe.yml` 每周一 09:17 跑一次（也可手动点）：查一次模型列表，挑出最新的 `claude-opus-*`，跟上面那两个 workflow 的 `claude_model` 默认值比。不一样推一条 Pushover，一样什么都不发。**只提醒，不自动改默认值** —— 改默认要改一行 + 合 PR + 移 `v1`，那一步是闸门，留在人手里。

**别拿别名 `opus` 当「最新」**：别名跟的是 Claude Code 的版本，不是模型发布。2026-10-04 在 Claude Code 2.1.266 上实测 `claude -p --model opus --output-format json`，回报的是 `claude-opus-5`，而当天最新的 Opus 已经是 `claude-opus-5-5`（2026-09-21 发布）—— 落后整整一代。所以探测走 `GET /v1/models`：只读、带发布时间、一次 HTTP 就够，不烧推理额度（令牌用现成的 `CLAUDE_CODE_OAUTH_TOKEN`，OAuth 令牌走 `Authorization: Bearer` + `anthropic-beta: oauth-2025-04-20`，不是 `x-api-key`）。

**同一条不重复推，盯的是模型本身，不是时间**：推成功那一轮会留下一份以模型 id 命名的凭据（本 workflow 的 artifact，叫 `opus-notified-<模型 id>`），下一轮先问「这份凭据在不在」——在就不推，不在就推。发布时间一概不参与这个判断：它是模型的发布时间，不是「我们第一次看见它」的时间，拿它当依据时，一个发布日期比上一次探测还早的新模型（灰度、列表滞后）会被判成推过了，然后永远不再提醒 —— 这是第一版的洞，`tests/probe-latest-opus.bats` 里有一条照它复现的测试守着。查不到凭据、凭据过期（仓库的 artifact 保留期，默认 90 天）、凭据没留上，一律按「没推过」算：最坏同一条重复推一次，不会把新模型咽掉。推送失败那一轮是红的，不留凭据，下一轮重试。「最新」认的是接口返回的顺序（文档写明新→旧），不自己按发布时间排：接口不知道发布时间时会填 1970 年，自己排会把这种新模型排到最后、永远挑不中。模型列表取不回来则红着停下、什么都不推（宁可没消息，也不要一条瞎报的消息）。

## 版本

各仓库的调用桩固定引用 `@v1`。改完这里的逻辑后要移动 tag 才会生效：

```
git tag -f v1 && git push -f origin v1
```

回退到 Claude 兜底之前的版本：`git tag -f v1 34645cf && git push -f origin v1`。

## 踩过的坑

- **顶层 `concurrency` 只能声明一次**：调用桩和被调用的可复用工作流若都在顶层声明同名 group，GitHub 判定「top level workflow」与该 job 死锁，run 立刻失败、零 job、无日志，只有一句 "This run likely failed because of a workflow file issue"。排队逻辑写在被调用方的 **job 层**，调用桩不要写 `concurrency`。`claude-codex-iterate` 踩了这个坑，2026-07-29 起 9 个仓库共 11 次触发全部空跑，直到 2026-08-20 才发现 —— 整条 Codex→Claude 迭代链从来没运行过。
- **云端的 Codex 修得好，但不会自己把改动推回 PR**：只发 `@codex fix`，它走订阅修好了（1 分 42 秒），然后停在它自己的任务页上等人点「更新分支」，设置里也没有自动推送的开关（MEL-266 实测，盯满 30 分钟）。能全自动的写法是**让它把改动贴成一段 diff**：同一句留言加上「paste the complete change as one unified diff」，75 秒就回了完整补丁，`git apply` 干净打上。所以留言原文写死，别改措辞。另外每个仓库都要先建 Codex 云端环境，否则它只回一句「先建环境」。
- **一条回复里有几个 diff 块就只能是一个**：零个、两个、开了没合上（GitHub 评论有长度上限，回复会被截断）一律当失败，宁可红着停下也不猜 —— 猜错就是把一段外部回复直接改进仓库，而下一步带着写权限令牌推出去。截断尤其阴：截在 hunk 中间 `git apply` 会拒，截在 hunk 边界上的却打得上，推出去就是半截修复。
- **补丁碰 `.github/workflows/` 一律拒**：推送用的令牌没有 workflows 权限（PR #18 实测推不上去），而且工作流文件正是这条流水线自己的防线。路径两头都要看 —— `git apply --numstat` 只报改动的去处，一次改名把工作流文件搬走它看不见，所以补丁自己的头行（`diff --git` / `---` / `+++` / `rename from|to`）也一起扫。
- **`github.job_workflow_sha` 实跑是空的，而空 `ref` 会让 `actions/checkout` 静默换一个**：取本仓库 `scripts/` 的那一步原来按它定版本。2026-10-02 实测两次（调用桩分别钉分支、钉 tag），checkout 的 `with:` 里连 `ref` 这一项都没出现 —— 值是空串。空 `ref` 不报错，checkout 退回事件自己的 ref：**在本仓库自己的 PR 上那就是被审 PR 的合并树**，于是被审 PR 自己提供了我们用来判它的脚本（换掉分类脚本就能买一次换人）；别的调用方仓库上那个 ref 在本仓库里不存在，整轮以一句看不懂的 checkout 错误收场。`v1` 标签还没移过，所以这一条从 PR #17 合入起一直没被跑到。改从本次 run 自己的记录里读：`GET /repos/{repo}/actions/runs/{id}` 的 `referenced_workflows` 按路径列出这次用到的每一份可复用工作流，带 `ref` 和 `sha`，是 GitHub 自己记下的事实，调用方和被审 PR 都改不动。读不出 40 位 commit 就红着停下，按路径筛出来的 commit 去重后不是恰好一个也红 —— 两个不同 sha 时挑一个（`first`）跟填空一样是在猜，只是这次猜的是版本（MEL-272）。**凡是「填空了会被某个 action 悄悄换成别的」的输入，都要先在 shell 里解析并验证，再交给它。**
- **不要放宽 `--allowedTools`**：Codex 的 review 正文是外部输入，直接进 Claude 的 prompt，而那个 token 有写权限。只放行具体命令，别用 `Bash(git:*)`。
- **`--allowedTools` 是全量清单**：`Edit,MultiEdit,Write` 不列出来 Claude 就改不了任何文件，只会干烧轮数。
- **绿勾 ≠ 有产出**：确认 Claude 真干了活要看 PR 时间线有没有评论和 commit。`claude-codex-iterate` 现在只在「推了新提交」和「看完觉得不用改」两种结局下报绿，缺凭证、额度耗尽、令牌失效、说推了却没推一律报红 —— 之前这些全被咽成 success，douyin-grabber 的自动修复因此一次都没跑起来还天天绿（MEL-236）。红的是 iterate 这条 run，`codex-approved-merge` 按名字把它排除在合并门槛外，不会因此卡住合并。
- **step 的 `if` 不写状态函数 = GitHub 隐式补一个 `success()`**：前面任何一步红了，后面所有这类 step 全被跳过，日志里只是安静的灰色。`claude-codex-iterate` 的 `Check the fix outcome` 当初只判 `gate.run`，`review_fixer: codex` 时它照跑、读到空结果就打红，Codex 接管那四步于是一次都没跑过，summary 还写着 `ran: codex`（MEL-250）。抽单个 `run:` 块的 bats 测试看不见这一层 —— 断言那一格的输出可以全绿，而那之后的每一步都被跳过；要守这条得按门禁语义重放整条 step 链（`tests/test_helper/step_gate.bash`）。
- **`git add -A` 放在验证之前，验证改的被跟踪文件会被静默丢掉**：先 add 是对的（验证会造出 `.venv` / `node_modules` / `__pycache__`，后 add 就一起提交了），但 `uv sync --dev` 默认重写 `uv.lock`、`npm ci` 重写 `package-lock.json`，这些差异不在暂存区里，commit 推出去的是一棵从没被测过的树。验证通过后补一次 `git add -u`：它只更新已经在索引里的路径，垃圾目录从没进过索引，照样进不来（MEL-252）。
- **验证跑完补的那次 `git add -u`，是外部 PR 的一条发布通道**：它把验证改过的**任何**被跟踪文件一起入索引，下一步带着写权限凭据提交推送 —— 验证命令往一个源文件里写一行，就借这条工作流的手发布了「复审机器人从没产出过的改动」。不能靠「一律拒绝验证后的改动」来堵：`uv sync --dev` 重写 `uv.lock` 是合法的，拒掉等于推翻上一条（提交验过的那棵树）。分法是白名单：验证**前后**各用一份 `mktemp` 出来的临时索引算一次 `add -u` + `write-tree`，两棵树不等就把 `git diff --name-only` 的路径逐条比 `verify_writable_paths`，有一条不在上面就红着停下，停在凭据塞回去之前。比树而不是比「`add -u` 会带进来哪些文件」：验证命令自己跑一条 `git add` 就能把新文件直接塞进真索引，那时候连 `add -u` 都不需要了。临时索引每次现开、结果只存在当前 shell 的变量里 —— 存成文件验证命令就改得动（MEL-258）。
- **比树只认「提交里装了什么」，认不出「提交落在哪儿」**：验证命令对工作副本有写权限，也就动得了这个仓库的提交历史，而下一步那次 `git commit` 的父亲、以及 `git push` 解析出来的东西，一样都不在树里。两条实跑复现过的路：① 先 `git commit` 一份带后门的载荷（HEAD 前进一格），再把索引恢复原样 —— 索引树一字不差地回到 `verify_tree_before`，比树那道门放行；外层那次 commit 落在已经前进过的 HEAD 上，那个中间的恶意 commit 就成了祖先，`push` 把它一起发布出去，而它在 PR 的最终 diff 里压根看不见。② 连 ref 都不用动：`git commit-tree` 造一个游离的 commit 对象，再写一个 `.git/MERGE_HEAD` 指过去，下一步那次 commit 就凭空多一个父亲 —— HEAD、全部 ref、树、`.git/config` 指纹，四样在验证前后完全一致（「先 commit 再 reset 回来」同理：只比首尾的快照看不见中间那一下）。**把下一步那次 commit + push 的全部输入整个拍成快照**：`HEAD`（符号引用指向谁 + 解析出来的 commit）、`git for-each-ref` 的全量 ref（tag / notes / stash / `refs/replace` 都在 `refs/` 底下，松散的和 `packed-refs` 里的一起认 —— 报的是解析之后的那一份，所以 `git pack-refs` 这种不改变解析结果的整理不会误红）、以及 `MERGE_HEAD` / `CHERRY_PICK_HEAD` / `REVERT_HEAD` / `MERGE_MODE` / `rebase-merge` / `rebase-apply` / `sequencer` / `shallow` / `info/grafts` 这几个「进行中的操作」哨兵。**比这份快照要排在比树之前**（提交落在哪儿比提交里装了什么更靠前），也排在「把凭据塞回去」之前；这一份必须走 `git` 去读，所以位置放在 `.git/config` 指纹之后 —— 那一条已经证明配置一个字节都没动，`git` 读 ref 的行为就没被掉包（MEL-261）。
- **跑被审 PR 自带的验证命令时，环境里不能有写权限凭据**：`npm ci` 的生命周期钩子、pytest 插件、bats 脚本都能执行任意命令，外部 PR 借此就能读走 `GH_TOKEN` 和 `actions/checkout` 持久化在 `.git/config` 里的凭证，拿到仓库写权限。**`env -u GH_TOKEN` 不算修好**：令牌还挂在 step 级 `env:` 上，父 shell 那份环境原样在，`ubuntu-latest` 上验证命令跟父 shell 同一个用户，`/proc/$PPID/environ` 读得回来。验证必须自成一步，而那一步的 `env:` 里根本没有令牌；`.git/config` 里的凭证验证前摘掉、跑完还回来，留给下一步 push。对应的测试也要断在「step 的 `env:` 声明」上 —— 只探子进程自己的 `${GH_TOKEN:-}` 的测试，对这种假修是绿的（MEL-252）。
- **`GITHUB_ENV` / `GITHUB_PATH` 是同一个洞的另一半**：验证子进程照样继承它们，往 `GITHUB_PATH` 追一个自带假 `gh` 的目录，后面「召唤复审」那步就会跑那个假 `gh` —— 而那步带的是 `CODEX_TRIGGER_TOKEN`。两道都要：子进程先拿到一组废纸篓文件，验证跑完再把真文件清空。少了后一道，它从 `/proc/$PPID/environ` 捞回真路径就直接写进去了；runner 在 step 收尾时才读这两个文件，最后写的是我们，所以清空有效。它们每个 step 一份，清空只丢本步自己写的东西（MEL-252）。
- **把令牌挪走不等于关上门：验证命令能往 `.git` 里种「下一步替它跑」的东西**。它对工作副本有写权限，于是可以写 `.git/hooks/pre-commit`（或 `commit-msg` / `pre-push` / `post-commit`），也可以往 `.git/config` 写 `core.hooksPath` 把钩子指到别处；下一步 `Commit and push` 会把 checkout 凭据塞回 `.git/config`、挂上 `GH_TOKEN`，然后 `git commit` 就替它跑了 —— 同时拿到两把写权限钥匙，而整条链 exit 0、push 正常、没有任何东西变红。**别只堵钩子**：`.git/config` 里会去跑命令的键还有 `credential.helper`（`!` 开头就是 shell）、`core.pager`、`gpg.program`、`filter.*.clean` / `.smudge`、`core.fsmonitor`，逐条列出来堵等于把「跟着复审意见一条条追」换个地方重演。两道：带凭据的 `git commit` / `git push` 加 `-c core.hooksPath=<$RUNNER_TEMP 下的空目录>`（命令行 `-c` 压得过任何配置文件里的同名键，种钩子和种 `core.hooksPath` 一起失效；`--no-verify` 挡不住 `post-commit`，别只靠它）；再给 `.git/config` + `.git/hooks` 做验证前后的指纹比对，一有差异就 `::error::` 非零退出。**比对必须排在「把凭据塞回去」之前** —— 凭据一回到 `.git/config`，种下的东西就有人替它跑了。指纹别拿 `git` 去算：要比对的正是 git 的配置（MEL-253）。
- **指纹拍的是仓库自己那份 `.git`，钥匙还能从旁边那扇门走**：验证命令改**机器上**的全局 / 系统 git 配置（`$HOME/.gitconfig`）不进指纹，指纹照样绿 —— 而全局配置里 `url.<base>.insteadOf` 配 `ext::` 传输、`credential.helper`、`gpg.program`、`core.fsmonitor`、`filter.*.clean` 每一个都会让 git 去跑一条外部命令，实测一条 `insteadOf` 就从带凭据的 `git push` 上把 `GH_TOKEN` 和 `extraheader` 一起捞走了。**别把全局配置也纳入指纹**：调用方仓库的测试套件顺手动一下全局 git 配置就整轮变红，19 个仓库一起收紧。按作用域关：验证之后每一条 git 都带 `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_SYSTEM` 指向 `/dev/null`（全局 + 系统一起作废，不用列键名；为什么是 `/dev/null` 而不是一个空文件，见下一条）。代价是 `actions/checkout` 写在全局配置里的 `safe.directory` 跟着丢掉，自托管 / 容器 runner 上会炸，所以那一项在命令行上显式补回来 —— 需要哪一项我们自己给，别的一律不继承（MEL-253）。

- **我们自己给 git 备的那份「空设置」，别落成验证命令改得动的文件**：`GIT_CONFIG_GLOBAL` 指向一个 `mktemp` 出来的空文件听着安全，可那文件在 `$RUNNER_TEMP` 下、在验证命令跑之前就建好、名字前缀还固定 —— 验证命令一个 `for f in "$RUNNER_TEMP"/no-gitconfig-*` 就把它改写成自己的 `core.fsmonitor`，而仓库 `.git` 一个字没动、指纹照样通过，接着「凭据塞回去之后」那次 `git add -u` 就替它跑了；那一刻指纹已经过去，它再往仓库自己那份 `.git/config` 写一个 `core.fsmonitor`，下一步带凭据的 `git commit` 连 `GH_TOKEN` 一起交出去。**空配置用 `/dev/null`**：永远读得到、永远是空的、它改不了。空钩子目录只能是真目录，所以仍然 `mktemp -d`，但**验证命令跑完、进程组收干净之后再换一个新的** —— 旧那个它看得见，往里丢一个 `post-index-change` 同样会被那次 `add -u` 执行（MEL-256）。

- **`.git/config` 的指纹要认「还是不是原来那个文件」，不能只认内容**：`sha256 <"$git_dir/config"` 跟着快捷方式走。验证命令把此刻还没凭据的 `.git/config` 复制到仓库里一个**已被跟踪**的文件、再把 `.git/config` 换成指向它的 symlink，内容一字不差、指纹通过；凭据塞回去时 git 顺着 symlink 写进了那个被跟踪的文件（`git config` 写之前会 resolve symlink 再 rename），紧接着的 `add -u` 把它入索引，下一步提交推送 —— **凭据明文进了 PR 的提交**。照钩子那一半已经写好的样子来：先判 `-L`，不是普通文件就红着停下（停在凭据塞回去之前），并把 inode / 权限位 / 链接数一起记进指纹（MEL-256）。
- **验证跑完还要确认它没留下活着的进程**：验证命令可以 fork 一个进程再让自己退出，指纹和废纸篓文件都不杀进程 —— 那个进程活到「凭据塞回 `.git/config`」和下一步导出 `GH_TOKEN` 的时候，同一个用户，轮询就能把钥匙捞走。`set -m` 让验证命令自成一个进程组（组号 = 该任务的 pid），跑完 `kill -- -组号` 整组收掉，TERM 扛得住的（`trap '' TERM`）再 KILL，**收干净之前不许把凭据塞回去**。`ps` 用不了就红着停下：这一道要是静默 no-op，比没有更糟（MEL-253）。
- **按进程组收尾挡不住一句 `setsid`**：验证命令起后台任务时加一句 `setsid`（或者自己来一次双重 fork），后代就换到新的会话、新的进程组，按组号去 `ps` 的收尾压根看不见它。它活到「凭据塞回 `.git/config`」那一刻就把钥匙抄走；更狠的是等指纹和白名单都判完之后再改一个源文件、自己 `git add`，下一步就替它提交推送 —— 前面那些判定一个都不作数了。**两道**：① 凭据摘掉之后**不再还回** `.git/config`，带凭据那一步自己用手上的 `GH_TOKEN` 现造一份（`actions/checkout` 写进去的就是 `AUTHORIZATION: basic base64(x-access-token:<token>)`），通过 `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_0` / `GIT_CONFIG_VALUE_0` 只递给那一条 `git push` —— 不落文件（落了就有人轮询）、不上命令行（`argv` 在 `/proc` 里公开）；② 「那一棵进程树死透了」要有**正面证据**，而证据不能建立在任何一样「它自己交得出去的东西」上。**继承的描述符不算**：工作流源码在 PR 里公开可见、描述符号写死在里面，验证命令开头一句 `exec 8>&-` 再 `setsid` 躲起来，我们这头立刻读到 EOF、判定「死透了」，而它还活着（Codex 2026-09-25 挂的 P1，审核方独立实跑复现）。进程组、会话、描述符它都能主动丢掉；丢不掉的只有**运行用户** —— 它没有提权手段，`fork` / `exec` / `setsid` 出来的每一个进程都还挂在同一个 uid 上，而「同一个 uid」正好就是它能读走凭据的那个条件。所以按 uid 正面清点：验证之前拍一份「这个用户当下有哪些进程」（身份 = pid + 启动时刻，只活在父 shell 的变量里，落文件它就改得动），跑完反复清点，直到某一刻这个用户名下除了基线里那些和我们自己的后代之外一个都不剩 —— 那一刻就是证据（真有哪一刻空了它就再也回不来，没有任何进程能把它拉起来）。5 秒内一直不空就红着停下，**不杀**：分不清那是逃逸的后代还是机器上别人的进程，误杀比红着停下糟。代价是本机跑测试时机器上别的长命进程刚好在这一瞬起来也会被记一笔（runner 上进程表干净，不会）—— 测试里靠「报出来的 pid 不是我们种的那个就重跑一遍」区分，重跑不会放过真逃逸（MEL-255）。
- **「凭据在 step 的 `env:` 里」不是靠挪位置能修好的**：Linux 上同一个 uid 的活进程从 `/proc/<pid>/environ` 就把它读回去了，放文件更糟（谁都能轮询），上命令行也一样（`argv` 公开），`unset` 改不掉 `/proc` 里那份初始环境。上一轮的验收记录写成「躲开之后它找不到任何可轮询的凭据」，这句话是错的 —— 凭据只是从文件挪进了进程环境。正确的说法是**不许有人等**：每个 step 是各自一个进程，验证那一步早已退出（死进程没有 environ），带凭据那一步在验证跑的时候还不存在，所以唯一的风险就是「验证留下了活进程」，上一条那道清点把它堵掉、清不干净就红着停下，带凭据那一步压根不会开始。想让 environ 连同一个用户也读不到，只有把验证命令换到另一个用户下跑 —— 2026-10-02 起默认就是这样（`verify_isolation`，MEL-289），于是「有人在等」这件事连资格都没有了；那个账号建不起来的 runner 上回退回同一个用户，上面这段仍然是回退路径的全部依据（MEL-255）。工作区归属走组权限（整个 `g+w` + 目录 setgid + 它那头 `umask 002`），所有权一个字不改，所以验证跑完我们照旧 `git add -u` / `git clean -fdx` 得动它造出来的 `.venv` / `node_modules`。
- **「令牌只在那一步里」这条对 Claude 那一步同样成立，而它没法靠挪令牌满足**：`anthropics/claude-code-action` 那一步必须握着写权限令牌（action 自己要用），所以唯一的办法是**让被审 PR 的代码进不来**：清单里删掉整条 runtime 工具链（`Bash(uv:*)` / `Bash(npm:*)` / `Bash(bats:*)`…，也就是 `extra_tools` / `EXTRA_TOOLS` 不再拼进 `--allowedTools`），删掉 `git add` / `commit` / `push` 和 `gh pr comment`，提示词里也不再让它自己跑验证 —— 它只改文件。验证、commit、push、发总结挪成后面四步，形状和判定跟 Codex 那条路逐行一致；总结文本走结构化输出的 `summary` 字段带出来发。顺带把 `actions/checkout` 的 `persist-credentials` 关掉：那份凭据躺在 `.git/config` 里，读个文件就换来仓库写权限，连种钩子都不用，而本 job 没有一步依赖它（两条路的 push 都自己现造一份）。代价是 Claude 不再能「跑测试 → 看见红 → 自己再修一轮」：验证红了这一轮就红着停下，跟 Codex 那条路一样等巡检重修（MEL-254）。
- **两份防线现在是逐行副本，改一份必须改另一份**：`Verify / Commit and push the Claude fix` 是 `... the Codex fix` 那两步的复制品。之所以不共用一份：Codex 那两步排在「换不换人」的裁决之后，Claude 那条路走不到它们那儿；而把判定抽成 `$RUNNER_TEMP` 下的共享脚本，等于请验证命令改写我们自己的防线。合成一份是单独一张票的事（MEL-254）。
- **PATH 前几项在 `$HOME` 下，验证命令写得动 —— 它能换掉我们后面要跑的命令本身**：`ubuntu-latest` 的 PATH 第一项就是 `/home/runner/.local/bin`（还有 `.cargo/bin`、`.dotnet/tools` 之类），验证命令跟我们同一个用户，往那儿放一个假 `ps` 就把自己从清点里隐掉、放一个假 `git` 就报一棵假的树、放一个假 `gh` 就在下一步直接拿到令牌 —— 指纹、白名单、清点全部变成空转，而 `.git` 一个字没动。**两步（验证、带凭据那一步）各自把 PATH 过滤成「我们写不动的目录」**：目录本身不可写还不够，上一级可写就能把整个目录换掉，所以连父目录一起看；原来那份 PATH 只交给验证命令自己（它要 `uv` / `npm` / `node` 那些装在 `$HOME` 下的工具）。过滤完少了 `git` / `ps` / `awk` 就红着停下 —— 这一道要是静默空转，比没有更糟。新加的「发总结评论」那一步照同一段过滤（它手上是 `github.token`）；少了 `gh` / `jq` 它只 warning 跳过评论，不红 —— 它排在判定结局那步之前，一红整条链就静默停住。凡是手上有凭据的步骤都照同一段过滤，一共十步（两条路各自的验证、提交推送、发评论，加上 `Check the fix outcome`、`Decide the takeover`、「请 Codex 出补丁」和「召唤复审」）—— 「召唤复审」和「请 Codex 出补丁」手上都是 `CODEX_TRIGGER_TOKEN`，是这一串里最该收紧的两步。少了工具红不红按「它一红会不会把链条静默停住」分：判定结局、裁决那两步红着停下，两条发总结评论和召唤复审只 warning 跳过。过滤那段判定**只认绝对路径**：相对项按 cwd 解析，而 cwd 就是被审 PR 的工作副本，而且「逐级往上剥父目录」碰到不带 `/` 的相对项会原地打转，整步挂到超时（MEL-260）。**测试怎么共存**：`tests/test_helper/fake-bin` 在仓库里、谁都写得动，过滤之后必然被滤掉。行为判定调 `trust_fake_bin` 把假命令接回去，安全判定（种一个假 `gh` 看它跑不跑）跑原样的块 —— opt-in 不是默认，忘了加是红，忘了关才是假绿。
- **过滤 PATH 的那段代码，本身也得先有个 bash 来跑**：步骤不写 `shell:` 时 runner 按当时的 PATH 找 `bash`，验证命令往 `~/.local/bin` 放一个假的，下一步一启动令牌就先交到它手里，过滤还没开始。所以 iterate 那个 job 在 job 层把 shell 钉成 `/usr/bin/bash --noprofile --norc -eo pipefail {0}`。单步写 `shell: bash` 会盖掉它；验证之后再出现 `uses:` 也一样（action 自己的步骤按 PATH 找 bash）。两条都有 bats 守着（MEL-278）。
- **PATH 过滤挡的是「跑哪个命令」，挡不住「加载哪个文件」**：`Check the fix outcome` 和 `Decide the takeover` 以前 `source` 一份放在 `$RUNNER_TEMP` 的告警函数文件。它是验证命令起跑之前写下的，而 `$RUNNER_TEMP` 验证命令写得动 —— 往里塞一行，就在握着 `github.token` 的那一步里跑起来，九步的 PATH 过滤一道都拦不住。现在同一份函数文本另走 step output 交过去：output 在验证命令起跑前已被 runner 收走，它改不到；文件只留给排在验证之前的 Gate 用。没拿到就红着停下。失败分类脚本（`classify-claude-failure.sh`）同一个毛病、同一个修法：正文在 PR 代码起跑前交给 step output，`Decide the takeover` 用写保护目录里的 bash 跑那份文本，不执行 `$RUNNER_TEMP` 里的文件 —— 否则换掉它既拿得到令牌，回一句「额度用完」还能把业务失败骗成换人（Codex 2026-09-26 / 10-01 的两条 P1，MEL-260）。
- **GitHub 托管 runner 给 `runner` 用户免密 `sudo`**：真要动它，上面这一整串（进程清点、PATH、指纹、白名单）全都绕得过去 —— 这一系列防的是「不动 sudo」的那一类验证命令，也就是 `npm ci` 的生命周期钩子、pytest 插件那种顺手就能执行任意代码的路子。别把这些防线当成「外部 PR 在 runner 上做不了坏事」。同一档的还有「先不留活进程、过后再起一个」：`crontab` / `at` / `systemd-run --user` 排一个一分钟后的任务，清点那一刻它名下确实干净，任务起来时带凭据那一步可能还在跑 —— 按 uid 清点管的是「此刻有没有人在等」，管不了「过后有没有人来」（MEL-255）。换到专用账号下跑之后这两条都塌了半边：那个账号不在 sudoers 里（`sudo` 对它直接失败），`systemd-run --user` / `crontab` 也没有服务管理器可问；回退路径上原样成立（MEL-289）。
- **`git clean -fd` 清不掉被忽略的残留**：Claude 撞额度前跑一半的 `uv sync` 留下的 `.venv`、`node_modules`、build 产物都躲在 `.gitignore` 后面，没有 `-x` 就原地留着跟进 Codex 那一轮，验证于是跑在一个被污染的工作区上。换人前的清理一律 `git clean -fdx`；本轮要留的东西（预取的 review 正文）在 clean 之前挪出工作区、clean 之后再放回来（MEL-252）。
- **`.git/info/exclude` 挡不住 `git reset --hard`**：exclude 只管 `git add` 和 `git clean` 不去碰**未跟踪**的文件；调用方仓库自己跟踪了同名文件时，`reset --hard` 照样把它恢复回来，把写在那儿的预取内容盖掉。工作区里放「只给这一轮用」的文件，要么放到工作区外，要么带上 run id（同「取脚本的落点必须带 run id」那条），别指望 exclude（MEL-252）。
- **关键那一步要排在前面，别排在发评论后面**：同上一条的门禁语义，`gh pr comment` 偶发失败一次，排在它后面的步骤就整个被跳过。`claude-codex-iterate` 里「召唤复审」一度排在「发总结评论」之后 —— 总结那步一抖，Codex 刚推的提交就没人复看，链条静默停住。链条上必须发生的事排前面，给人看的排后面（MEL-252）。
- **`@codex review` 会被限流静默**：连发几次后连 👀 都不回，约 10 分钟恢复。现在 iterate 只召唤一次，沉默由 watcher 的 5 分钟兜底接手。
- **Codex 额度用完时它照样回一条评论**：旧版超时告警把它当成「Codex 有反应」，于是既不告警也不合并，PR 就这么卡住（2026-09-17，3 个 PR）。现在认出这句话就当场换 Claude。
- **秒合并的 PR** 会让 Codex 迟到的 review 落在已关闭的 PR 上，job 被跳过是正常现象。
- **密钥只写不读，个人账号也没有账号级密钥**：存进仓库后连 API 都取不回值（`gh api repos/X/actions/secrets/NAME` 只返回名字和日期），共享密钥是 organization 才有的功能。所以 `secrets.env` 是唯一母本 —— 在网页上手填过的值必须补回母本，否则接新仓库时无处可取（2026-07-30 为此翻了半天 `~/.claude/history.jsonl`）。
- **Regenerate PAT 会立刻作废旧值**：换完要把所有仓库的 secret 一起刷新；换的是 `CODEX_TRIGGER_TOKEN` 的话，本仓库的 `SELF_WORKFLOWS_TOKEN` 也要按上面那条命令重设（`onboard.sh` 不管它，漏了本仓库的 PR 又推不动、合不动流水线文件）。漏掉的那个 CI 照样绿，只有 Codex 复审那步静默停住。
- **bats 里别直接写 `[[ ... ]]`**：中途失败的 `[[ ]]` bats 抓不住，只认最后一条命令的退出码，测试于是假绿（一条明知会挂的断言照样报 ok）。用 `tests/test_helper/common.bash` 里的 `assert_equal` / `assert_contains`，函数返回非零它抓得住。
- **接完要把仓库默认分支改成 `develop`**：`onboard.sh` 起手要求默认分支是 `main`（它靠 main 建 develop），但完成后会自动改成 `develop`。如果这步失败，必须手动补；否则 `gh pr create` 不带 `--base` 会打向默认分支。linear-agent-team 忘了改，agent 开的 3 个 PR 全合进 main，develop 停在初始 commit（2026-07-30）。
- **Claude 那一步只认默认分支上的调用桩**：`anthropics/claude-code-action` 自己会校验「触发这次 run 的那份工作流文件，内容跟仓库默认分支上的是否一字不差」，不一样就整步跳过，日志只有一句 `Skipping action due to workflow validation`。于是**演练时把调用桩临时钉到别的 ref（分支、tag、sha）这招对 Claude 那条路是走不通的**：action 不跑、没有任何结构化输出，`Check the fix outcome` 按「业务失败」收口，整轮红（MEL-200 实测，run 37255446498）。Claude 那条路只能拿默认分支上原样的调用桩演练 —— `v1` 等于 `develop` 尖端时它本来就是在跑新代码。Codex 接管那条不受影响：它压根不调这个 action，钉 sha + 传 `review_fixer: codex` 照跑（MEL-200 实测，run 37256040590）。
- **被审 PR 进门时 CI 就得是绿的，否则这一轮多半到不了推送**：fixer 只管复审意见，而验证那一步跑的是本仓库全套验证命令。所以 PR 身上只要有**复审没提到的** lint 问题，补丁打得再干净，验证照样红、什么都不推（MEL-200 实测：演练 PR 自带一个 shellcheck 的 SC2086，Codex 的意见是另一回事，于是 `verification: failed, nothing was pushed`，run 37255492609；补上引号重跑，同一条路立刻走完五步）。验证看的是补丁打完以后的代码，所以真正拦住推送的是**补丁打完还剩下的** lint 问题，两个 fixer 都一样。差别在于剩下的概率：Claude 那条的 prompt 明确不让它跑 lint / 测试，它看不到这类问题，除非按复审意见改的恰好是同一行、顺带把问题改没了，否则这种 PR 在那条路上推不出去；Codex 接管那条的请求只叫它「修复审意见、回一份 diff」，没禁它在云端自己跑 lint，所以它顺手把别的问题也修掉、验证碰巧转绿的可能更大一些 —— 两条都别指望这个。这不是 bug：自动修复接手的前提是「除了复审指出的那些，别的都已经是绿的」；排查时见到哪条偶尔绕过去了，也不代表这个前提可以不管。
