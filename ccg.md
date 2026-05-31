---
description: Code Change Guardian — multi-model review, AI commit gate, merge conflict resolution, and pre-push analysis.
---

# CCG v3 — Code Change Guardian

> **4-Stage Guardian**: Two independent AI model families guard every change across Review · Commit · Merge · Push—surfacing where they disagree, auto-filtering low-risk changes, and providing a pre-push quality gate before code leaves your machine.

## 三柱设计

| 柱 | 解决的问题 | 实现 |
|---|---|---|
| Divergence Engine | 单源 review 看不到"自己看不到的盲区" | 同 prompt 双投喂 + Claude 综合时强调分歧 |
| Risk-Aware Routing | 用户不应该手选 cost/balanced/quality | `ccg_risk_score` 基于路径/内容/规模规则打分自动选 |
| Review Ledger | 这次评审的判断下次没法复用 | 每次评审追加 JSONL，按路径可查历史 |

## 配置 (环境变量)

| 变量 | 默认 | 说明 |
|---|---|---|
| `CCG_MODE` | `auto` | `auto` (按 risk score 决) / `cost` / `balanced` / `quality` |
| `CCG_CODEX_MODEL` | — | 显式 codex 模型（优先于 CCG_MODE） |
| `CCG_GEMINI_MODEL` | — | 显式 gemini 模型 |
| `CCG_CODEX_TIMEOUT` | `240` | Codex 超时秒数 |
| `CCG_GEMINI_TIMEOUT` | `120` | Gemini 超时秒数 |
| `CCG_NO_CACHE` | `0` | `1` = 跳过 24h prompt-hash 缓存 |
| `CCG_CACHE_TTL_HOURS` | `24` | 缓存 TTL |
| `CCG_MAX_PROMPT_KB` | `100` | 防止把整个 repo 塞进 prompt |
| `CCG_KEEP_ARTIFACTS` | `0` | `1` = 保留临时文件 |
| `CCG_LEDGER_LOG` | `$XDG_DATA_HOME/ccg/ledger.jsonl` | 评审历史落盘位置（fallback `~/.local/share/ccg/`，自动迁移老路径 `~/.ccg/`） |
| `CCG_NO_REPORT` | `0` | `1` = 跳过 `.ccg/reports/<sha>_<ts>.md` 持久化 |
| `CCG_REPORT_DIR` | `<repo>/.ccg/reports` | 改写报告目录（默认 git repo 根下的 `.ccg/reports/`） |
| `CCG_NO_HISTORY` | `0` | `1` = 跳过把过去同路径的评审摘要注入 prompt（步骤 2.5） |
| `CCG_HISTORY_MAX` | `3` | 注入 prompt 的历史评审条数上限 |

### Mode → 默认模型映射

| Mode | Codex | Gemini |
|---|---|---|
| `cost` | deepseek-v4 | qwen-3.7 |
| `balanced` (默认) | gpt-5.4 | gemini-2.5-flash |
| `quality` | gpt-5.5 | gemini-3.5-flash |

> ⚠️ 第三方代理若不支持上述模型名，会 5xx/404。用 `CCG_CODEX_MODEL`/`CCG_GEMINI_MODEL` 显式指定代理实际支持的型号。

## 前置依赖

- `npm i -g @openai/codex` `npm i -g @google/gemini-cli`
- `export GEMINI_API_KEY=...` 放在 `~/.zshenv`（非交互 shell 也能读到）

## 执行协议（Claude 严格按以下步骤）

### 步骤 0. 初始化工作目录

```bash
source ~/.claude/commands/ccg.sh
ccg_init
```

**⚠️ 跨 Bash 调用 env vars 不持久。把输出的字面 `CCG_DIR=...` 路径记住**，后续每个 Bash 调用开头先 `CCG_DIR=<字面路径>` 重建。

### 步骤 1. 预检

```bash
source ~/.claude/commands/ccg.sh
ccg_preflight
```
- `CCG_PREFLIGHT_CODEX=missing` → 说明缺哪个 CLI + 安装命令
- `CCG_PREFLIGHT_GEMINI=no-api-key` → 标注 Gemini 不可用，跳过
- 两者都不可用 → Claude 独立回答

### 步骤 2. 确定任务输入（两种模式）

**A. 用户给了参数**（如 `/ccg 评审 src/auth.ts`）：直接用用户输入作为 prompt。跳过 risk_score（让用户隐式选 mode 或用环境变量）。

**B. 用户没给参数**（裸 `/ccg`）：**自动评审 git diff**：

```bash
CCG_DIR=<字面路径>
source ~/.claude/commands/ccg.sh
ccg_diff_capture "$CCG_DIR/diff.txt"
```

- `CCG_DIFF_OK` + `CCG_DIFF_SOURCE=worktree` → 工作区脏改动
- `CCG_DIFF_SOURCE=staged` → 已 git add 但未 commit
- `CCG_DIFF_SOURCE=upstream:<branch>` → 已 commit 但未 push（或本地领先上游）
- `CCG_DIFF_SOURCE=origin-head` → 没有上游时，对比 origin/HEAD
- `CCG_DIFF_FAIL=not-a-git-repo` → 提示用户在 git 仓库下使用，或显式给参数
- `CCG_DIFF_FAIL=empty-diff` → 提示用户 "工作区干净 + 分支已对齐上游，没东西要评审"

**Claude 必须在最终输出中显示对比的是哪个 source，让用户知道评审的范围。**

### 步骤 2.5. 历史评审注入（让 ledger 不再 write-only）

```bash
CCG_DIR=<字面路径>
source ~/.claude/commands/ccg.sh
ccg_ledger_context "$CCG_DIR/diff.txt"
```

读 `CCG_HISTORY_*`：
- `CCG_HISTORY_OK=<n>_matches_<max>_max` + `CCG_HISTORY_FILE=<path>` → 文件已写入 `<CCG_DIR>/history.txt`，**步骤 4 写 prompt 时必须把这段内容拼到 diff 前面**
- `CCG_HISTORY_NONE=0_matches` → ledger 里没匹配（首次评审这些文件）；正常情况，prompt 不带 history 块
- `CCG_HISTORY_SKIPPED=<no-ledger|no-diff|disabled|no-paths-in-diff>` → 跳过即可，不报错
- `CCG_HISTORY_FAIL=...` → 临时文件写不进；忽略并继续（这一步是增强信号，不是必需）

> 设计立场：L6 ledger 不再是日记本——每次评审都把"过去对同一文件的判断"作为先验喂给 Codex/Gemini。recurring patterns、未解决的 fix-required 都进入第一现场。环境变量 `CCG_NO_HISTORY=1` 可关闭；`CCG_HISTORY_MAX` 改条数（默认 3）。

### 步骤 3. 风险打分 + 自动选 mode（仅 B 模式）

```bash
CCG_DIR=<字面路径>
source ~/.claude/commands/ccg.sh
ccg_risk_score "$CCG_DIR/diff.txt" | tee "$CCG_DIR/risk.txt"
```

读取 `CCG_RISK_MODE`：
- 用户已设 `CCG_MODE` 非空非 auto → 尊重用户选择
- 否则用 risk_score 给的 mode：`export CCG_MODE=<推荐值>`

> 设计立场：路径/内容/规模规则比 LLM 判断更**可解释、零成本、可改**。社区贡献者可以直接 PR 改权重。

### 步骤 4. 写 prompt（结构化输出协议）

**核心改动**：要求两端都按下面格式输出（便于 Claude 后续做对齐和分歧检测）。

Prompt 模板：

````
你是代码评审者。仔细评审下面这段 diff，按 *严格* 的输出格式：

===FINDINGS===
[FINDING]
file: <path>:<line>
severity: critical|high|medium|low|nit
category: bug|security|perf|readability|test|other
title: <一行）
detail: <2-4 行解释，必须可独立读懂>
[/FINDING]
（每个发现一个 [FINDING]…[/FINDING] 块；按 severity 倒序）

===VERDICT===
<3-5 行：整体判断 + 是否阻塞合并>

===END===

不要寒暄，不要在外面加任何文字。如果没有发现问题，FINDINGS 段落留空，但格式仍要保留。

<如果 step 2.5 产出了 history.txt，把它的完整内容贴在这里，标题"=== PRIOR REVIEWS ===" 自带>

待评审的 diff（source: <CCG_DIFF_SOURCE>）：

<贴入 diff 内容>
````

用 **Write tool**（不是 echo）写入：
- `<CCG_DIR>/codex.prompt`
- `<CCG_DIR>/gemini.prompt`

两份 prompt 内容**完全相同**（包括 history 段——两个 reviewer 看相同的过往）。让两个独立大脑产生差异——这正是分歧检测的来源。

### 步骤 5. 并行调用 CLI（单消息两个 Bash 调用）

helper 内部：检查大小 → 查缓存（命中则 $0）→ 真打 API → 落 cache + usage.log。

**Codex** (timeout 260000)：
```bash
CCG_DIR=<字面路径>
source ~/.claude/commands/ccg.sh
ccg_codex "$CCG_DIR/codex.prompt" "$CCG_DIR/codex.result"
echo "---ANSWER---"
cat "$CCG_DIR/codex.result"
```

**Gemini** (timeout 140000)：
```bash
CCG_DIR=<字面路径>
source ~/.claude/commands/ccg.sh
ccg_gemini "$CCG_DIR/gemini.prompt" "$CCG_DIR/gemini.result"
echo "---ANSWER---"
cat "$CCG_DIR/gemini.result"
```

**两个 Bash 调用必须在同一条 assistant message 内发出**，才能真并行。

### 步骤 6. 实际成本

```bash
CCG_DIR=<字面路径>
source ~/.claude/commands/ccg.sh
ccg_actual "$CCG_DIR/codex.prompt" "$CCG_DIR/codex.result" codex
ccg_actual "$CCG_DIR/gemini.prompt" "$CCG_DIR/gemini.result" gemini
```

### 步骤 7. 健康判定 + 综合输出（**Pillar 1 关键**）

| Codex | Gemini | 路径 |
|---|---|---|
| OK | OK | 完整三段输出（AGREEMENT / DIVERGENCE / BLINDSPOT）|
| OK | FAIL | 只能输出 Codex 视角，标注分歧无法验证 |
| FAIL | OK | 只能输出 Gemini 视角，标注分歧无法验证 |
| FAIL | FAIL | Claude 独立回答 + 标注顾问不可用 |

**Claude 的综合规则（必须严格遵守）：**

1. **解析两边的 [FINDING] 块**，按 `(file, line, category, title 关键字)` 做对齐。Levenshtein 不重要，类别 + 文件 + 大致位置一致即视为同一发现。

2. **AGREEMENT**：两边都报告了的发现。**降级展示**——通常这种问题 Claude 自己也能发现，新增信息量低。一句话带过即可，**不要展开**。

3. **DIVERGENCE**：核心。**每条都展开**，必须包含：
   - 一方说什么、另一方说什么（或没说）
   - Claude 的判断：哪边更可能对？为什么？
   - 用户行动建议（接受 / 驳回 / 需要人决定）
   - 如果 Claude 也判断不了，**明确说"NEEDS HUMAN DECISION"**——这是工具最有价值的输出，不要装得自己都懂。

4. **BLINDSPOT**：Claude 综合时怀疑两边都漏掉的点。慎用，每次最多 1-2 条，不要为了凑数硬挤。

5. **VERDICT**：merge / fix / discuss 三选一，给一句话理由。

### 步骤 8. 综合输出模板（**严格按此格式**）

```
## CCG v3 综合结果

📍 评审范围：<source 标签，如 worktree | staged | upstream:origin/main>
🎯 模式：<mode>（risk score: <分数> ｜ 触发: <reasons>）
🩺 顾问状态：Codex ✓ ｜ Gemini ✓
💰 本次成本：Codex $0.0023 + Gemini $0.0008 = **$0.0031**

═══ AGREEMENT (N) ═══
两边都指出，新增信息量低：
- file:line — 简短描述（不展开）
- ...

═══ DIVERGENCE (M) ═══   ★ 这一段是 ccg 的核心价值 ★

▸ DIV#1 — file:line
  🔵 Codex: <Codex 的判断>
  🟢 Gemini: <Gemini 的判断 / 没提到>
  ⚖️  Claude 综合: <哪边更可信，为什么>
  ➡️ 建议: <accept Codex / accept Gemini / NEEDS HUMAN DECISION>

▸ DIV#2 — ...

═══ BLINDSPOT (≤2) ═══
两边都没提但 Claude 怀疑：
- ...（如果不确定就不写）

═══ VERDICT ═══
<merge | fix-required | discuss>
<一句话理由>

═══ 来源原文（折叠展示）═══
🔵 Codex (gpt-5-mini): <VERDICT 段原样>
🟢 Gemini (gemini-2.5-flash): <VERDICT 段原样>
```

**关键纪律：**
- AGREEMENT 段越短越好；DIVERGENCE 段越展开越好。这反映 ccg 的产品立场。
- 任何"NEEDS HUMAN DECISION"的 DIVERGENCE 必须明确 — 这是 ccg 的核心价值信号
- 失败原因摘要给用户（helper 已脱敏 API key/URL）
- 用户没问怎么修，不给修复代码

### 步骤 9. 落 ledger

把上面综合输出的**完整**核心结论写到 `$CCG_DIR/synthesis.txt`（ledger 自动截断前 400 字符做摘要；持久化报告则使用完整内容），然后：

```bash
CCG_DIR=<字面路径>
source ~/.claude/commands/ccg.sh
ccg_ledger_record "$CCG_DIR"
```

### 步骤 10. 持久化报告到仓库（让评审结果在 session 结束后还能被找到）

```bash
CCG_DIR=<字面路径>
source ~/.claude/commands/ccg.sh
ccg_persist_report "$CCG_DIR"
```

- `CCG_REPORT_OK=<path>` → 把这个路径告诉用户："本次评审完整记录已写入 `<path>`"
- `CCG_REPORT_SKIPPED=not-a-git-repo` → 跳过持久化（不在 git 仓库下），是正常情况，不要报错
- `CCG_REPORT_SKIPPED=disabled` → 用户显式 `CCG_NO_REPORT=1`，不要报错
- `CCG_REPORT_FAIL=<reason>` → 提示用户检查 `.ccg/reports/` 目录权限

报告位置（默认）：`<repo_root>/.ccg/reports/<sha-or-WIP>_<UTC-timestamp>.md`。建议用户把 `.ccg/` 加入 `.gitignore`（首次出现时可顺手提醒一句）。

### 步骤 11. 清理

```bash
CCG_DIR=<字面路径>
source ~/.claude/commands/ccg.sh
ccg_cleanup "$CCG_DIR"
```
`CCG_KEEP_ARTIFACTS=1` 时跳过（调试用）。

## 用量与历史查询（用户主动触发）

```bash
source ~/.claude/commands/ccg.sh
ccg_usage --this-month                          # 本月成本
ccg_usage --all                                 # 全部
ccg_usage --since=2026-05                       # 自指定时间起

ccg_ledger_query                                # 最近 5 条评审
ccg_ledger_query "src/auth.ts"                  # 这个文件历史评审过几次
```

## /ccg ship — 一键交付（review → commit → merge）

**语义**：`/ccg ship [target-branch] [commit-message]` = 把当前分支的 staged 改动 review 后提交，再合并到 target。

| 命令 | 含义 |
|---|---|
| `/ccg ship` | staged → autocommit → merge 到默认保护分支 |
| `/ccg ship main` | staged → autocommit → merge 到 main |
| `/ccg ship main "feat: login"` | 同上，指定 commit message |

**执行协议（Claude 必须严格按以下步骤）：**

### 步骤 S.1 调用 ccg_ship

```bash
source ~/.claude/commands/ccg.sh
ccg_ship "<target-branch>" "<commit-message>"
```

helper 内部自动：
1. 若有 staged 改动 → 调 `ccg_autocommit`（AI review → 通过才 commit）
2. 若无 staged 改动 → 跳过 commit，直接进入 merge
3. 调 `ccg_merge <target>` → AI 辅助合并，冲突自动解决

### 步骤 S.2 解读输出

| 输出 | 含义 |
|---|---|
| `CCG_SHIP_COMMITTED=1` | staged 改动已通过 review 并 commit |
| `CCG_SHIP_COMMITTED=0` | 没有 staged 改动，跳过 commit |
| `CCG_SHIP_DONE=1` | 全流程完成 |
| `CCG_SHIP_FAIL=autocommit-blocked` | review 不通过，commit 被阻断，merge 未执行 |
| `CCG_SHIP_FAIL=merge-blocked` | commit 成功但 merge 失败（冲突需人工处理） |

### 步骤 S.3 输出格式

```
## 🚀 CCG Ship 结果

**分支**：`<source>` → `<target>`

**Step 1 — Commit**：✅ 已提交 / ⏭️ 无 staged 改动（跳过）/ ❌ review 不通过（已阻断）

**Step 2 — Merge**：✅ 合并完成 / ⚠️ 需人工处理冲突 / ❌ 失败

<如果 merge 有冲突，原样转发 ccg_merge 的冲突报告表格>
```

### 环境变量

| 变量 | 说明 |
|---|---|
| `CCG_GATE_OFFLINE=1` | 跳过 AI review，直接 commit |
| `CCG_MERGE_DRY_RUN=1` | merge 演练，不实际提交 |
| `CCG_MERGE_NO_FETCH=1` | 跳过 fetch（离线环境） |

---

## /ccg merge — AI 辅助合并（用户主动触发）

**语义**：`/ccg merge [target-branch]` = **把当前分支合并到 target**。

| 命令 | 含义 |
|---|---|
| `/ccg merge` | 站在 `feature` 上，合并到默认保护分支（main → master → develop 顺序） |
| `/ccg merge develop` | 站在 `feature` 上，合并到 `develop` |
| `/ccg merge feature` 站在 `main` 上 | ❌ 报 same-branch（请先 checkout feature 再用） |

> **重要**：参数是"合并到哪"，不是"合并什么"。你的当前分支永远是 source。

**执行协议（Claude 必须严格按以下步骤）：**

### 步骤 M.0 安全前置

调用前**强制确认**：
- 当前分支(source) = `git rev-parse --abbrev-ref HEAD`
- 工作区是否干净？
- 目标分支是否存在？（helper 内部会校验，但 Claude 必须在 prompt 里告知用户即将合并的是 `<current> → <target>`）

### 步骤 M.1 调用 ccg_merge

```bash
source ~/.claude/commands/ccg.sh
ccg_merge "<target-branch>"          # 不传参数则默认 main/master/develop
```

helper 内部自动：
1. 校验工作区干净（脏则 `CCG_MERGE_FAIL=dirty-working-tree` 退出）
2. **备份 target 分支**（受影响的那一方）到 `ccg-backup/<target>-<timestamp>`
3. `git checkout <target>` — 切到 target 让 merge commit 落在那
4. `git merge --no-commit --no-ff <source>` — 把当前分支合并进 target
5. 无冲突 → 直接 commit + 输出 `CCG_MERGE_RESULT=clean`
6. 有冲突 → 解析所有冲突块 → 并行调 Codex+Gemini 决策每个冲突
7. AI 给 `NEEDS_HUMAN_DECISION` 的冲突 → 不 commit，**留在 target 分支上**供人审

### 步骤 M.2 解读 helper 输出

| 输出 | 含义 | 给用户怎么说 |
|---|---|---|
| `CCG_MERGE_SOURCE=<x>` + `CCG_MERGE_TARGET=<y>` | 标识本次方向 | 一定要明确告诉用户：source → target |
| `CCG_MERGE_RESULT=clean` + `CCG_MERGE_COMMITTED=1` | 合并完成、无冲突 | "✅ `<source>` 已合并到 `<target>`，你现在在 `<target>` 分支" |
| `CCG_MERGE_RESULT=conflicts` + `CCG_MERGE_COMMITTED=1` | 有冲突，AI 解决了，已 commit | 展示冲突报告表格（helper 已输出） |
| `CCG_MERGE_BLOCKED=needs-human` | 部分冲突 AI 不敢决策，**未 commit** | "你在 `<target>` 分支（未 commit 的 merge 状态）。请审查 `<files>`，确认后 `git commit`，或 `git merge --abort && git checkout <source>` 撤销" |
| `CCG_MERGE_FAIL=dirty-working-tree` | 工作区脏 | "请先 `git commit` 或 `git stash` 当前改动" |
| `CCG_MERGE_FAIL=same-branch` | 当前已经在 target 上 | "你已经在 `<target>` 分支上。请先 `git checkout <feature>` 再合并" |
| `CCG_MERGE_FAIL=target-not-found:<x>` | target 分支不存在 | "目标分支 `<x>` 不存在。本地分支：`git branch`，远程：`git branch -r`" |
| `CCG_MERGE_FAIL=no-target-branch` | 找不到默认保护分支 | "请显式指定目标分支：`/ccg merge <branch>`" |

### 步骤 M.3 输出可视化合并报告（**严格按此格式**）

helper 已经在 stdout 输出了 Markdown 表格，Claude **必须原样转发**给用户，并在表格前后加摘要：

````
## 🔀 CCG Merge 报告

**Source**：`<source_branch>`（你的工作分支）
**Target**：`<target_branch>`（被合并到，已自动切到此分支）
**Backup**：`ccg-backup/<target>-<ts>`（target 合并前的快照，后悔时可恢复）

<helper 输出的 OURS/THEIRS 表格原样贴在这里>

> 表格中：OURS = target 分支原内容，THEIRS = 你的 feature 改动

═══ 决策摘要 ═══
- ✅ AI 解决：N 处
- ⚠️ 需人审：M 处（如有，列出 file:idx）

═══ 你现在在哪 ═══
- 如果 CCG_MERGE_COMMITTED=1：你已切到 `<target>`，合并已完成，可以 `git push origin <target>`
- 如果 CCG_MERGE_BLOCKED：你在 `<target>` 但 merge 未 commit，请审查冲突文件

═══ 撤销方法 ═══
- 撤销已 commit 的合并：`git reset --hard ccg-backup/<target>-<ts>`
- 撤销未 commit 的合并：`git merge --abort && git checkout <source>`
````

### 关键纪律

1. **永远不要弄混 source/target**：source 是用户的工作分支（current），target 是要合并到的地方（参数/默认）
2. **OURS = target**：因为 git checkout target 后，target 的内容就是 ours
3. **NEEDS_HUMAN_DECISION 不要替用户决策**：明确告诉用户"AI 不敢决，请你看"
4. **保留双方代码**：AI 默认行为是合并双方逻辑，绝不静默丢弃任何一方
5. **可视化优先**：表格比一段一段叙述清楚 10 倍

### 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `CCG_MERGE_DRY_RUN` | `0` | `1` = 跑全流程但不 commit（预览模式，结束时切回 source） |
| `CCG_MERGE_NO_AI` | `0` | `1` = 跳过 AI 解决，保留冲突标记给人手工解 |

## 故障排除

| 症状 | 原因 | 解决 |
|---|---|---|
| `CCG_PREFLIGHT_CODEX=missing` | 没装 Codex CLI | `npm i -g @openai/codex` |
| `CCG_PREFLIGHT_GEMINI=missing` | 没装 Gemini CLI | `npm i -g @google/gemini-cli` |
| `CCG_PREFLIGHT_GEMINI=no-api-key` | 任何 shell 模式拿不到 `GEMINI_API_KEY` | 写到 `~/.zshenv` |
| `CCG_DIFF_FAIL=not-a-git-repo` | 不在 git 仓库 | cd 进仓库；或显式给参数 |
| `CCG_DIFF_FAIL=empty-diff` | 工作区干净 + 分支与上游对齐 | 改点东西；或显式给参数；或对比指定 ref |
| `CCG_*_FAIL=prompt-too-large-Nb-max-Mb` | prompt 超过 100KB | 缩小范围，或 `CCG_MAX_PROMPT_KB=500` |
| `CCG_*_FAIL=Model ... not registered / 503` | 代理不支持当前模型 | 显式 `CCG_CODEX_MODEL=<代理支持的型号>` |
| `CCG_GEMINI_FAIL=error-leaked-to-stdout` | 代理把错误写到 stdout | 检查 `$CCG_DIR/gemini.err`（需 `CCG_KEEP_ARTIFACTS=1`） |
| `CCG_*_FAIL=timeout-Ns` | CLI 超时 | 调大 `CCG_*_TIMEOUT` |
| `CCG_REPORT_FAIL=cannot-create-dir:...` | `.ccg/reports/` 无法创建 | 检查仓库目录写权限或设 `CCG_REPORT_DIR=/path/you/own` |
| `CCG_REPORT_SKIPPED=not-a-git-repo` | 当前目录不在 git 仓库里 | 这是预期行为，不报错；要持久化就 cd 进仓库或显式给 `CCG_REPORT_DIR` |
| `CCG_HISTORY_SKIPPED=no-ledger` | 还没攒下评审历史 | 这是预期行为；多跑几次 `/ccg` 后历史就有了 |
| `CCG_HISTORY_NONE=0_matches` | 这次 diff 触及的文件之前没评审过 | 这是预期行为，prompt 里不带 history 块 |

## 已知设计取舍

- **Divergence over consensus**：放弃"给一份完整 review 报告"，转向"标记需要人裁决的点"。AGREEMENT 段意识形态上**故意降级**——单源 Claude 也能发现，无新增信号
- **Ledger 双向化**：v3.x 起 ledger 不再只写——`ccg_ledger_context` 在每次评审前把"过去对同一文件的判断"作为先验注入 prompt。recurring patterns 和未解决的 fix-required 进入第一现场，不再随 session 关闭而蒸发。这是把 L6 从"日记本"升级成"结构化记忆"。
- **同 prompt 双投喂**：训练数据差异自然产生多样性，比拍脑袋分工（codex=arch、gemini=ux）更可靠
- **24h 缓存**：调试同段代码反复跑时省 90% 费用；改了代码 prompt hash 自然变了，无需手动失效
- **prompt 大小硬限**：100KB ≈ 32k token，比 codex/gemini context window 小一个数量级，防止把 repo 塞进去
- **风险打分纯规则**：可解释、零成本、社区可改。LLM 自我打分会跟主评审产生循环
- **Ledger JSONL**：append-only、grep-able。前 50 次看不出价值，长期是 stateless 工具复制不来的护城河
- **失败不入缓存**：FAIL 的调用既不入 cache 也不入 usage.log（$0 失败不该污染历史）

## 注意事项

- 不要在 prompt 中泄露密钥（helper 会脱敏 stderr 和 ledger，但不脱敏 stdin）
- Codex exec 在沙箱中运行，不会修改本地文件
- 价格估算 ±15%（基于字符数 / 3.0 启发式）；要精确请用 tiktoken
