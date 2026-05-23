# 架构

> 受众：贡献者和集成者。如果你只是想用 `ccg`，读 [README.zh-CN.md](../README.zh-CN.md)。如果你想 **改 ccg**，读这份文档。
>
> 真相来源：本文描述 `ccg.sh` 和 `bin/ccg.js` 里**代码真实做的事**——不是营销话术声称的。如果有出入，用 `grep -n '^ccg_\|^_ccg_' ccg.sh` 对照函数名。
>
> 翻译同步说明：本翻译跟随英文版 [docs/ARCHITECTURE.md](ARCHITECTURE.md)；如有滞后请以英文版为准。

[English](ARCHITECTURE.md) ｜ **简体中文** ｜ [日本語](ARCHITECTURE.ja.md) ｜ [한국어](ARCHITECTURE.ko.md)

---

## 1. 诚实的一句话定位

ccg 是 **在 Claude Code 里调用 Codex + Gemini CLI 的生产级编排层**。

这是工程真相。"代码分歧检测器"是叠在六个底层之上的 [L7 产品钩子](#l7--分歧综合claude-端)——这六层每一层都独立解决一个真实工程问题，否则你从 slash command 里 shell-out 到 LLM CLI 会立刻撞上。

> 删了 L7，ccg 仍然有用（缓存、账本、用量、风险路由）。
> 删了 L1，ccg 不安全。
> 产品故事卖的是 L7。工程实质是 L1–L6。

---

## 2. 七层架构

```
┌─────────────────────────────────────────────────────────────────────────┐
│  L7  分歧综合  （存活于 ccg.md prompt，由 Claude 执行）                  │
│      AGREEMENT / DIVERGENCE / BLINDSPOT 三段输出                        │
├─────────────────────────────────────────────────────────────────────────┤
│  L6  评审账本           ccg_ledger_record / ccg_ledger_query             │
│      JSONL append-only，grep 可查，机密脱敏                              │
├─────────────────────────────────────────────────────────────────────────┤
│  L5  风险路由           ccg_risk_score                                   │
│      纯规则评分 diff → cost / balanced / quality                         │
├─────────────────────────────────────────────────────────────────────────┤
│  L4  用量遥测           ccg_actual / ccg_usage / _ccg_log_usage          │
│      USD 感知、模型感知、月度感知                                         │
├─────────────────────────────────────────────────────────────────────────┤
│  L3  智能 diff 抓取     ccg_diff_capture                                 │
│      4 级回退: worktree → staged → upstream → origin-head                │
├─────────────────────────────────────────────────────────────────────────┤
│  L2  内容寻址缓存       _ccg_cache_lookup / _ccg_cache_store             │
│      SHA-256 prompt+model key · 24h TTL · 失败调用不缓存                 │
├─────────────────────────────────────────────────────────────────────────┤
│  L1  安全 CLI 调度      _ccg_run_with_timeout / _ccg_redact /            │
│      ccg_cleanup / _ccg_check_prompt_size / mktemp 700 隔离              │
└─────────────────────────────────────────────────────────────────────────┘

       ↑                                       ↑
   bin/ccg.js                            ~/.claude/commands/ccg.sh
   (Node CLI: install/about/doctor)      (Bash 核心，Claude source 它)
```

每一层都能独立调用。`bash -c 'source ccg.sh; ccg_risk_score diff.txt'` 完全不碰 L7 就能跑。

---

## 3. 七层详解

### L1 — 安全 CLI 调度
**问题：** 从 shell-out 调用 `codex < prompt.txt` 在 5 个方面都不安全：没超时、后台子进程的 stdin 被重定向到 `/dev/null`、API key 泄漏到日志、prompt 大小无界、临时目录在崩溃时残留。

**解法：**
- `_ccg_run_with_timeout` — bash 3.2+ 跨平台超时。优先 `timeout` / `gtimeout`；fallback 到纯 bash 轮询 + 墙钟期限。关键一行：后台子进程显式 `<&0` 保留 stdin（bash 默认把后台任务 stdin 重定向到 `/dev/null` 是知名陷阱）。
- `_ccg_redact` — 7 个正则模式：`sk-*`、`AIza*`、`Bearer *`、JWT 形 token、`ghp_*`、`AKIA*`、Slack `xox[bpoas]-*`。外加 URL 查询串。每次 stderr 捕获 + 每次 ledger synthesis 写入前都过一遍。
- `ccg_cleanup` — 拒绝相对路径、`..`、符号链接、非 `ccg.` 前缀的 basename，然后才 `rm -rf`。还做 UID 隔离的孤儿目录扫描（保守 24h 阈值）。
- `_ccg_check_prompt_size` — 默认 100KB 单次上限。防止"我不小心把 5MB diff 灌进去然后被收 $5"。
- `ccg_init` — `mktemp -d` 配 0700；并发调用永不冲突。

**删了这层：** ccg 变成一个会泄密、会留下孤儿目录的 `echo prompt | codex` 包装。不可发布。

---

### L2 — 内容寻址缓存
**问题：** 调试同一个 diff 反复跑 review（尤其在迭代 ccg 自身时）每次都掏钱。codex CLI 和 gemini CLI 都没有"这跟上次调用一样"的认知。

**解法：**
- Key = `sha256(prompt_contents) + model_id`。同 prompt + 同模型 = 必然命中。
- Value = LLM 输出的完整原文。
- TTL = 24h（`CCG_CACHE_TTL_HOURS` 可配）。
- **失败隔离：** 调用返回 `_FAIL=` 或空时**不**缓存。否则一次瞬时 503 会毒化 24h 缓存。
- 存储位置 `$XDG_CACHE_HOME/ccg/cache/`。随时 `rm -rf` 安全——最坏情况是多付一次费。

**删了这层：** 调试循环成本翻 ~5 倍。不会不安全，只是贵。

---

### L3 — 智能 diff 抓取
**问题：** `git diff` 只显示未提交改动。一旦 `git commit`，`cursor /review` 这类工具就"没东西可审"。但**分支领先于上游**才是最重要的审查窗口——它马上要 merge。

**解法：** `ccg_diff_capture <out_file>` 按 4 个 source 依次回退：

| 顺序 | Source | 触发条件 |
|---|---|---|
| 1 | `worktree` | `git diff HEAD` 输出非空 |
| 2 | `staged` | `git diff --cached` 输出非空 |
| 3 | `upstream:<branch>` | `git rev-parse @{u}` 能解析 + `git diff @{u}` 非空 |
| 4 | `origin-head` | `git rev-parse origin/HEAD` 能解析 + `git diff origin/HEAD` 非空 |

选中的 source 通过 `CCG_DIFF_SOURCE` 暴露给调用者（L7 里的 Claude）标记 review。还会返回 `CCG_DIFF_FAIL=not-a-git-repo` 或 `=empty-diff` 作为非异常的显式哨兵让协议处理。

**删了这层：** ccg 静默丢失"已提交未推送代码的 review 能力"——这是单兵开发最有价值的 review 窗口。

---

### L4 — 用量遥测
**问题：** 没有任何 LLM CLI 告诉你"这个月花了 $X"。`gh copilot` 没有，`codex` 没有，`gemini` 没有。成本直到收账单才可见。

**解法：**
- `ccg_actual <prompt> <result> <provider>` — 调用 AFTER 测量。读 prompt + result 的真实字节数，通过 `_ccg_tokens_from_chars`（`chars / 3.0` 启发式；误差 ~15%）算 token，乘以 `_ccg_price(model, direction)`，追加一行到 `$XDG_DATA_HOME/ccg/usage.log`。
- `ccg_usage [--this-month|--all|--since=YYYY-MM]` — 汇总日志。
- **缓存命中记 $0.00**，保证累计准确。
- **失败调用根本不记** —— 一次 503 不应该被算成 $0.001 支出。

格式：`<iso_ts> <provider> <model> in=<n> out=<n> usd=<float>`。故意用纯文本——`grep` 和 `awk` 都能用。

**删了这层：** 成本变成传说。你每月花 $30，不知道花在哪。

---

### L5 — 风险感知路由
**问题：** `cost` / `balanced` / `quality` 模式 60 倍价差（≈$0.0007 vs ≈$0.0440 单次）。每次让用户选是 UX 灾难。让 LLM 自选会造成反馈循环。两个都不对。

**解法：** `ccg_risk_score <diff_file>` 是纯规则评分——这一层没有 LLM。读 diff 返回：

```
CCG_RISK_SCORE=72
CCG_RISK_MODE=quality
CCG_RISK_FILES=5
CCG_RISK_LINES=+340-12
CCG_RISK_REASONS=auth+40 sql_interp+30 size>300+15 docs_only-40
```

`ccg.sh:ccg_risk_score` 里的规则：

| 信号 | 权重 | 检测 |
|---|---|---|
| 路径含 `auth\|payment\|migration\|crypto\|security` | +25..+40 | 路径正则 |
| 内容含 `exec\|eval\|spawn` 或 `sql.*interp` | +20..+30 | patch 内容正则 |
| 硬编码 URL/host 字面量 | +5 | 正则 |
| TODO/FIXME/HACK 标记 | +5 | 正则 |
| diff > 600 行 | +25 | 行数统计 |
| 文件 > 8 个 | +10 | hunk 数 |
| 仅文档改动（`.md` / `.txt` / `.rst`） | **-40** | 路径扩展名 |

**阈值：** `< 20 → cost`，`< 60 → balanced`，`≥ 60 → quality`。

**为什么不用 LLM：** 透明、零成本、权重可 PR。社区贡献者可以 `sed -i 's/+40/+50/' ccg.sh` 然后提 1 行 PR。换成 LLM 评分器，每次路由决策都变成黑箱。

**删了这层：** 用户每次都得手动设 `CCG_MODE`，或者一直付 `quality` 的钱。

---

### L6 — 评审账本
**问题：** 所有 LLM CLI 都是无状态的。"两周前 Codex 对 `src/auth.ts` 说了什么？"——没有任何工具能回答。

**解法：** `ccg_ledger_record <workdir>` 每次评审追加一行 JSONL 到 `$XDG_DATA_HOME/ccg/ledger.jsonl`：

```json
{"ts":"2026-05-22T18:35:06Z","repo":"/path","branch":"feat-x","sha":"91c16ec",
 "mode":"quality","risk":72,"files":1,"lines":"+5-0","paths":["auth/login.go"],
 "synthesis":"divergence on constant-time compare; NEEDS HUMAN DECISION..."}
```

`synthesis` 字段是 Claude 综合裁定的前 ~400 字——足够有用，又短到能 grep 翻 1000 条。

`ccg_ledger_query` 操作：
- `ccg_ledger_query` — 最近 5 次评审。
- `ccg_ledger_query "src/auth"` — 涉及此路径片段的评审，含计数 + 最近 3 个日期。

**前 50 次看不出价值。**累积到 50 条后变成"结构化记忆"——这是无状态工具不可复制的——长期护城河就在这。

**删了这层：** ccg 变成 100% 无状态。每次评审从头开始。L7 产品故事仍能跑，但长期差异化没了。

---

### L7 — 分歧综合（Claude 端）
**问题：** 单模型 code review（Copilot、Cursor `/review`、Aider）看不到自己的盲区。哪怕模型再聪明，也只有一种视角。

**解法：** 真相来源是 `ccg.md` 里的 slash-command 协议，**不是某个库函数**。Claude：

1. source `ccg.sh`，调用 `ccg_init` 分配 workdir。
2. 调用 `ccg_preflight` 检查 Codex + Gemini 可用性。
3. 调用 `ccg_diff_capture`（L3）落 diff 文件。
4. 调用 `ccg_risk_score`（L5）选模式。
5. 写一份 prompt 文件。同 prompt，不同消费者。
6. **并行**调用 `ccg_codex` + `ccg_gemini`（两个 Bash tool 调用在同一条 Claude message 里）。
7. 调用 `ccg_actual`（L4）记真实成本。
8. **综合**两个 `[FINDING]` 格式输出为 AGREEMENT / DIVERGENCE / BLINDSPOT 三段——综合发生在 Claude 脑子里，不在代码里。
9. 调用 `ccg_ledger_record`（L6）写 synthesis 摘要。
10. 调用 `ccg_cleanup`（L1）移除 workdir。

协议显式**降级** AGREEMENT 可见性（每条一行）+ **提升** DIVERGENCE（完整展开 + "NEEDS HUMAN DECISION" 标签）。这是产品意见：一致 = 低信号，分歧 = 价值。

**删了这层：** ccg 仍然有用——可以调用单个函数做成本遥测、风险路由、账本查询。但用户面向的 `/ccg` 工作流消失。

---

## 4. 端到端数据流

一次 `/ccg` 调用，按时间顺序，每步标注哪层负责：

```
用户在 Claude Code 输入 "/ccg"
       │
       ▼
[Claude 读 ccg.md 协议]                                     ── 协议
       │
       ▼
ccg_init                                                    ── L1
  └─ mktemp -d -m 700 /tmp/ccg.XXXXXXXX
  └─ 输出 CCG_DIR=<path>
       │
       ▼
ccg_preflight                                               ── L1
  └─ command -v codex / gemini, $GEMINI_API_KEY 检查
       │
       ▼
ccg_diff_capture "$CCG_DIR/diff.txt"                        ── L3
  └─ 4 级回退 → 输出 CCG_DIFF_SOURCE
       │
       ▼
ccg_risk_score "$CCG_DIR/diff.txt"                          ── L5
  └─ 规则评分 → 输出 CCG_RISK_SCORE + CCG_RISK_MODE
  └─ Claude 按推荐 export CCG_MODE
       │
       ▼
[Claude 写 codex.prompt + gemini.prompt — 同内容]           ── 协议
       │
       ▼
ccg_codex   ─ 并行 ─  ccg_gemini                            ── L1 + L2
  │           │             │
  │   L1: 超时 + 脱敏 + stdin <&0
  │   L2: 缓存查找 → 命中则返回，否则跑 CLI 然后存缓存（仅成功）
  │
  └─ 双方都写 *.result 文件
       │
       ▼
ccg_actual <prompt> <result> codex|gemini                   ── L4
  └─ 测 token，算 USD，追加到 usage.log
       │
       ▼
[Claude 综合 AGREEMENT/DIVERGENCE/BLINDSPOT]                ── L7
  └─ 按 (file, line, category, title) 对齐 [FINDING] 块
  └─ 不可调和分歧标 "NEEDS HUMAN DECISION"
       │
       ▼
[Claude 写 synthesis.txt — 前 400 字符]                     ── 协议
       │
       ▼
ccg_ledger_record "$CCG_DIR"                                ── L6
  └─ JSON 编码 + 脱敏 synthesis + 追加 ledger.jsonl
       │
       ▼
ccg_cleanup "$CCG_DIR"                                      ── L1
  └─ 路径遍历安全的 rm -rf
       │
       ▼
用户看到: AGREEMENT / DIVERGENCE / BLINDSPOT + 成本行
```

典型总延迟：5–60 秒（看模式）。成本：$0.0007–$0.044，被 `CCG_MAX_PROMPT_KB` 封顶。

---

## 5. 扩展点

这些是贡献者和集成者可以依赖的契约。改签名 = 破坏性改动。

### 5.1 新增风险评分规则（L5）

编辑 `ccg.sh:ccg_risk_score`，加一段 `if/then` 递增 `score` 并追加 `reasons`。输出契约：

```
CCG_RISK_SCORE=<int 0..200>
CCG_RISK_MODE=<cost|balanced|quality>
CCG_RISK_FILES=<int>
CCG_RISK_LINES=+<adds>-<dels>
CCG_RISK_REASONS=<信号+权重 信号+权重 ...>
```

其他东西按 KEY=VAL 行解析此输出。

### 5.2 新增 LLM provider（L1 + L2）

以现有为例：`ccg_codex` 和 `ccg_gemini` 已经实现契约。要加 `ccg_claude`：

1. 从 `CCG_MODE` 解析模型 id（参考 `_ccg_resolve_codex_model`）。
2. 构建包含新 provider 名的缓存 key。
3. `_ccg_cache_lookup` → 命中就写 result 文件返回。
4. `_ccg_run_with_timeout <timeout> <cli> -i <prompt> > <result> 2> <err>`。
5. 成功后 `_ccg_cache_store`。
6. 输出 `CCG_CLAUDE_OK=<size>` 或 `CCG_CLAUDE_FAIL=<reason>`。

`ccg.md` 协议要更新以并行调用新 helper。

### 5.3 改存储路径

所有路径走 `_ccg_xdg_data_dir` / `_ccg_xdg_cache_dir` / `_ccg_xdg_config_dir`。按 XDG Base Directory 规范用 `XDG_*_HOME` 覆盖；或对单个文件设 `CCG_USAGE_LOG` / `CCG_LEDGER_LOG` / `CCG_CACHE_DIR`。

老路径 `~/.ccg/` 首次启动时由 `_ccg_migrate_legacy` 自动迁移——幂等，非破坏性。

### 5.4 自定义定价

`_ccg_price <provider> <model> <direction>` 返回每百万 token USD。改这个表，下次 `ccg_actual` 立刻生效。

### 5.5 自定义 synthesis 输出格式

综合发生在**Claude 脑子里**，遵循 `ccg.md` 里的模板。要改格式（比如加 "SECURITY DIVERGENCE" 段），编辑 `ccg.md` 步骤 4 + 8 里的 prompt 模板。Bash 端不解析 synthesis。

---

## 6. 测试套件验证的不变量

`tests/test_ccg.sh` 强制这些——最近一次跑 99 个测试。违反任一会破 CI。

| 不变量 | 为什么 |
|---|---|
| `ccg_init` 永远返回 `/tmp` 或 `$TMPDIR` 下的 workdir，不会落 `$HOME` | 崩溃安全：残留的 workdir 不会污染用户家目录 |
| workdir 基名以 `ccg.` 开头 | `ccg_cleanup` 白名单的安全防线 |
| 失败的 CLI 调用永不进缓存或用量日志 | 一次性 503 不能毒化遥测/缓存 |
| stderr 里的机密在任何文件写入前都脱敏 | 7 模式正则表 |
| `ccg_diff_capture` 永远不返回"成功且 diff 为空" | 调用者可以假设 payload 非空 |
| 空文件的 risk score → `_FAIL=` 而不是 0 | 区分"0 风险"和"无信号" |
| ledger 行永远是合法 JSON，能被 `json.loads` 解析 | 既能 grep 又能解析 |
| `_ccg_run_with_timeout` 精确保留子进程退出码 | 调用者能区分 124（超时）和 1（CLI 错误） |
| 子 shell 从父继承 `set -u` 而不在未设变量上崩 | 兼容严格模式宿主 |

---

## 7. 值得了解的设计决策

这些选择第一眼看着怪，但都有原因。写下来防止未来贡献者"修好它"。

| 决策 | 看着怪因为 | 真实原因 |
|---|---|---|
| Bash 3.2+ 兼容（不用 `mapfile`、`${var,,}`） | 现代 bash 5.x 有更好语法 | macOS 自带 bash 3.2（GPL3 抵制问题）。bash 5 要显式 `brew install`。ccg 必须开箱可用 |
| 缓存 key 包含模型 id，不只是 prompt hash | "同 prompt 必然同结果"听起来对 | gpt-5-nano 缓存的结果不能当 gpt-5 结果。不同模型，不同输出。 |
| AGREEMENT 段刻意每条一行 | 一般更详细更好 | 如果两个 AI 都标记同一问题，你单一 Claude 也能发现。展开 AGREEMENT 反而稀释 DIVERGENCE 信号。这是产品意见，不是 UX 失误 |
| 风险评分纯规则，不用 LLM | LLM 可能更聪明 | 成本（零）、可解释性（regex grep）、"权重可 PR" 胜过边际精度。也避免评分器自身预测影响什么进入 review 的反馈循环 |
| 失败调用不被短暂缓存 | "负缓存能防止重试风暴" | 失败通常意味着"模型名错"或"限流"。两者都希望你修好后立刻重试。缓存失败会延迟恢复 |
| `~/.ccg/` 迁移用 `mv` 不用 `cp` | 可能留下孤儿 | 旧 `~/.ccg/` 用户显式 opt-in 了 env 变量；复制留下重复。我们一次性 move；空 dir 才删 |
| `ccg_cleanup` 拒绝符号链接，不只是 `..` | "路径遍历"是常见唬人话术 | `mktemp` 已经防 `..`。符号链接才是真实攻击面（清理过程中 swap 的 TOCTOU 竞态） |
| Slash command 协议活在 `ccg.md` 不在代码里 | 代码即文档看着更干净 | Claude 把 `ccg.md` 当协议规范读。Bash 代码不能当 Claude 的 prompt；这是 slash command 的本质。把协议（md）和原语（sh）分开是正确边界 |

---

## 8. 非目标

ccg 故意**不**做这些，以及原因。

- **不做流式输出。** Claude 必须同时拿到 Codex 和 Gemini 完整结果才综合。流式需要不同协议设计（也不会降本——两个评审者还是要跑完）。
- **不做多轮对话。** 每次 `/ccg` 是新的；没有 `continuation_id`。要迭代就再跑一次，缓存让重复便宜。
- **不做 Claude Code 之外的 IDE 集成。** Cursor / Continue / Cline 用户看 [zen-mcp-server](https://github.com/BeehiveInnovations/zen-mcp-server)。维护 N 个 IDE port 的测试负担不值得。
- **不做静态分析。** 分歧检测 ≠ Semgrep / CodeQL。和它们配合用，不是替代。
- **不做"review bot"。** ccg 由人触发。每个 PR 自动跑会制造噪音，违背"分诊工具"定位。

---

## 9. 真正的护城河在哪

营销定位喊的：**分歧检测**（L7）。

工程护城河实际是 **L6（账本） + L4（用量）**：

- L7 一周就能被抄。任何团队知道 `gpt-5-mini` + `gemini-2.5-flash` 就能复刻同样的把戏。
- L6 + L4 产出**按用户累积的数据**。重度用户用 6 个月后，有了竞品复制不出来的个人历史记录——人家要从第 1 次 review 开始攒。

如果你要决定先加固哪个，**先加固 L6 + L4**。

---

## 10. 文件地图

```
ccg/
├── ccg.sh                       → L1–L6 全部活在这里（Bash 核心）
├── ccg.md                       → L7 slash-command 协议（Claude 读，不被解析）
├── bin/ccg.js                   → Node CLI wrapper (install / uninstall / doctor / about)
├── scripts/install.sh           → 本地 clone 安装器
├── scripts/curl-install.sh      → 远程一行装
├── tests/test_ccg.sh            → 99 个回归 + 对抗测试 (L1–L6)
├── README.md                    → 英文入口（zh-CN / ja / ko 镜像）
├── docs/ARCHITECTURE.md         → 英文架构文档
├── docs/ARCHITECTURE.zh-CN.md   → 本文档
└── package.json                 → npm 发布清单 (@mcgrapeng/ccg)
```

有疑问时：**`bash ccg.sh` 是真相，本文档是地图**。如果两者矛盾，代码赢，本文档错。
