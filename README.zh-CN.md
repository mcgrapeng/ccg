# `/ccg` — 代码分歧检测器

[![Tests](https://img.shields.io/badge/tests-99%20passing-brightgreen.svg)]()
[![npm](https://img.shields.io/npm/v/@mcgrapeng/ccg.svg)](https://www.npmjs.com/package/@mcgrapeng/ccg)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[English](README.md) ｜ **简体中文** ｜ [日本語](README.ja.md) ｜ [한국어](README.ko.md)　·　[架构文档 →](docs/ARCHITECTURE.md)

> **不是"更好的代码审查工具"，而是代码分歧检测器。**
> 大多数 AI 审查工具追求共识。`/ccg` 反其道而行——并行调用 Codex（OpenAI）和 Gemini（Google）评审同一份 diff，再让 Claude **聚焦两个模型的分歧**——这才是真正需要人来拍板的地方。一致 = 低信号，分歧 = 黄金。

---

## 核心论点

| 现有 AI 审查工具 | `/ccg` |
|---|---|
| 单一模型、单一视角 | 两个独立模型家族（训练数据不同） |
| 输出是长篇审查报告 | 输出是**分歧地图** |
| 你瞥一眼"看着没问题" | 你看到"Codex 标了 X，Gemini 不认同，需要人判断" |
| 像 pre-commit 钩子（通过 / 阻塞） | 分诊工具（这 2 个点才真值得想） |

这个定位是独一份的。我们没找到第二个**以揭示 AI 分歧为产品目标**的开源工具，而不是给出答案。

---

## 三柱设计

### 第一柱 — 分歧引擎
同一个 prompt 同时投给 Codex 和 Gemini，要求结构化 `[FINDING]` 输出。Claude 综合后吐出三段：

```
AGREEMENT (N)    — 两边都标记 → 低信号，每条一行带过
DIVERGENCE (M)   — 判断不一致 → 展开，★ 需要人决定
BLINDSPOT (≤2)  — 两边都没看见，Claude 怀疑 → 慎用
```

AGREEMENT 段**故意写短**。产品立场：如果两个 AI 都标记的同一个问题，你自己用 Claude 也能发现，新增信息量低。DIVERGENCE 才是价值所在。

### 第二柱 — 风险感知路由
你不应该手动选 `cost` / `balanced` / `quality`。`ccg_risk_score` 看 diff 做确定性打分（这一层无 LLM）：

| 信号 | 权重 |
|---|---|
| 路径含 `auth/payment/migration/crypto/security` | +25..+40 |
| 内容含 `exec/eval/spawn` 或 SQL 拼接 | +20..+30 |
| diff > 600 行 | +25 |
| 文件 > 8 个 | +10 |
| 只改文档 | **-40** |

分数 < 20 → cost。< 60 → balanced。≥ 60 → quality。手动指定永远优先。

打分规则**可解释、零成本、可 PR**——任何人都能调权重。

### 第三柱 — 评审账本
每次评审追加一行 JSONL 到 `$XDG_DATA_HOME/ccg/ledger.jsonl`（fallback `~/.local/share/ccg/ledger.jsonl`；老的 `~/.ccg/` 自动迁移）：

```json
{"ts":"2026-05-22T18:35:06Z","repo":"/path","branch":"feat-x","sha":"91c16ec",
 "mode":"quality","risk":60,"files":1,"lines":"+5-0","paths":["auth/login.go"],
 "synthesis":"divergence on constant-time compare; NEEDS HUMAN DECISION..."}
```

查询用法：

```bash
ccg_ledger_query                    # 最近 5 次评审
ccg_ledger_query "src/auth"         # 这条路径被评审过多少次
```

前 50 次看不出价值，长期积累成"结构化记忆"——这是无状态工具复制不来的护城河。

---

## 安装

二选一，都会把 `/ccg` slash 命令装到 `~/.claude/commands/`。

### 方式 1 — npm（推荐）

```bash
npx @mcgrapeng/ccg install        # 一次性，零全局污染
# 或
npm i -g @mcgrapeng/ccg && ccg install
```

### 方式 2 — curl 一行装（无需 Node）

```bash
curl -fsSL https://raw.githubusercontent.com/mcgrapeng/ccg/main/scripts/curl-install.sh | bash
```

### 然后装 AI CLI

```bash
npm i -g @openai/codex @google/gemini-cli
echo 'export GEMINI_API_KEY="<你的-key>"' >> ~/.zshenv
```

验证：

```bash
npx @mcgrapeng/ccg doctor         # 或：ccg doctor
```

开启一个新的 Claude Code 会话，输入 `/ccg`。

## 用法

```bash
# 自动模式：抓 git diff → 风险打分 → 跑评审 → 综合 → 落账本
/ccg

# 显式任务（跳过风险打分，用 CCG_MODE 若已设）
/ccg 评审 src/queue.ts 里的 lock-free 队列实现

# 强制 mode
CCG_MODE=quality /ccg

# 强制指定模型
CCG_CODEX_MODEL=o3 /ccg

# 查询历史
source ~/.claude/commands/ccg.sh
ccg_usage --this-month
ccg_ledger_query "src/payment"
```

## diff 抓取很智能

`/ccg` 按 4 个 source 依次回退：

| Source | 何时触发 |
|---|---|
| `worktree` | 未提交的工作区改动 |
| `staged` | `git add` 过但未 commit |
| `upstream:<branch>` | 工作区干净，但分支领先 `@{u}`（已提交未推） |
| `origin-head` | 没设上游，但有 `origin/HEAD` |

选中的 source 会在 `CCG_DIFF_SOURCE` 报告出来，你永远知道在审什么。**提交工作不再让 `/ccg` 看不到**。

## 成本透明

定价快照 2026-05（USD / 1M tokens，官方 API）：

| Mode | Codex | Gemini | 每次典型成本¹ |
|---|---|---|---|
| `cost`     | gpt-5-nano   | gemini-2.5-flash-lite | ~$0.0007 |
| `balanced` | gpt-5-mini   | gemini-2.5-flash      | ~$0.0046 |
| `quality`  | gpt-5        | gemini-2.5-pro        | ~$0.0440 |

¹ 1500 字符 prompt + ~500 输出 token。命中缓存：$0.0000。

每次调用后 `/ccg` 按实际字节算成本。`ccg_usage --this-month` 看累计。

## 配置

| 变量 | 默认 | 用途 |
|---|---|---|
| `CCG_MODE` | `auto` | `auto` / `cost` / `balanced` / `quality`。`auto` 走风险打分 |
| `CCG_CODEX_MODEL` | （mode 默认） | 覆盖 codex 模型 |
| `CCG_GEMINI_MODEL` | （mode 默认） | 覆盖 gemini 模型 |
| `CCG_CODEX_TIMEOUT` | `240` | Codex 硬超时（秒） |
| `CCG_GEMINI_TIMEOUT` | `120` | Gemini 硬超时（秒） |
| `CCG_NO_CACHE` | `0` | `1` = 绕过 prompt 缓存 |
| `CCG_CACHE_TTL_HOURS` | `24` | 缓存 TTL |
| `CCG_CACHE_DIR` | `$XDG_CACHE_HOME/ccg/cache` | 缓存目录 |
| `CCG_MAX_PROMPT_KB` | `100` | prompt 大小硬限 |
| `CCG_USAGE_LOG` | `$XDG_DATA_HOME/ccg/usage.log` | 用量日志路径 |
| `CCG_LEDGER_LOG` | `$XDG_DATA_HOME/ccg/ledger.jsonl` | 账本路径 |
| `CCG_KEEP_ARTIFACTS` | `0` | `1` = 保留 workdir 调试用 |

## 生产级特性（99 个测试验证）

| 特性 | 实现 |
|---|---|
| **并发安全** | 每次调用 mktemp 唯一目录，mode 700，永不冲突 |
| **跨平台超时** | 回退到纯 bash 实现，亚秒级轮询 + 墙钟期限 |
| **stdin 保留** | 后台子进程显式 `<&0`——修了 bash 默认把 async stdin 重定向到 /dev/null 这个坑 |
| **清理安全** | 拒绝相对路径 / `..` / 符号链接 / 非 `ccg.` 前缀的 basename |
| **孤儿目录扫描** | 24h 保守阈值，按 UID 隔离 |
| **密钥脱敏** | 7 个 pattern：sk- / AIza / Bearer / JWT / ghp_ / AKIA / Slack + URL 查询串 |
| **优雅降级** | 任一 CLI 失败 → 用剩下的模型 + Claude 继续 |
| **缓存安全** | 失败不缓存；缓存 key = (prompt SHA-256 + model)；TTL 自动过期 |
| **用量精确** | 只记成功调用 + 真实 token 数 + USD；命中缓存记 $0.00 |
| **prompt 大小保护** | 默认 100KB 硬上限，防止意外 $5 一次的评审 |
| **diff 抓取 4 级回退** | worktree → staged → upstream → origin-head，`CCG_DIFF_SOURCE` 报告来源 |
| **风险打分透明** | 纯规则，返回理由串（如 `auth+35 sql_interp+30 size>300+15`） |
| **账本 JSON 校验** | 每行通过 `json.loads`；synthesis 摘要写入前已脱敏 |
| **分发保护** | `BASH_SOURCE[0] == $0` 检测，防止"被 source 时还带参数"的误触发 |

## 测试

```bash
bash tests/test_ccg.sh                # 99 个测试，~31s
REAL_CLI=1 bash tests/test_ccg.sh     # +2 个真实 API 测试（会扣费）
```

## `/ccg` 不是什么

- **不是 `/review` / `/code-review` 的替代** —— 那些是深上下文单源审查。`/ccg` 用于你希望"非 Claude 视角"评审高风险改动的场景
- **不是对话工具** —— 每次调用是新的；没有 `continuation_id`
- **不是流式** —— 两个评审者都跑完才综合
- **不是多宿主** —— 只支持 Claude Code。Cursor / Cline 见 [zen-mcp-server](https://github.com/BeehiveInnovations/zen-mcp-server)
- **不是安全扫描器** —— 分歧检测 ≠ 静态分析。配合 Semgrep / CodeQL 使用

## 与同类工具对比

| 工具 | 定位 | 输出 | 聚焦分歧？ |
|---|---|---|---|
| GitHub Copilot Reviews | 单模型 PR 审查 | 行内 comment | ❌ |
| Cursor `/review` | 单模型行内审查 | 修改建议 | ❌ |
| zen-mcp-server | 多模型 MCP 网关 | 通用对话 | ❌（追求共识） |
| Aider `/review` | 单模型 | 编辑感知建议 | ❌ |
| **`/ccg`** | **多源分歧检测器** | **AGREEMENT / DIVERGENCE / BLINDSPOT** | **✅ 核心产品** |

## `/ccg` 闪光时刻

- **高风险改动**：auth / 支付 / 迁移 / 加密——正好是你想知道"另一个模型有没有看到我漏掉的东西"的场景
- **合并前 PR 评审**：分支领先上游时 `/ccg` 自动评审 branch delta
- **单兵安全网**：没有人评？`/ccg` 是最接近"第二双眼睛"的存在

## `/ccg` 是过度

- 重命名变量
- 一行 typo 修复
- README 改动
- 测试覆盖充分的常规重构

风险路由会自动把这些降到 `cost` 模式（~$0.0007），但说实话：直接 commit 走人就行。`/ccg` 在 5–10% 的关键改动上才赚回成本。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。

## 致谢

- [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) 提供了最初的 `/ccg` 概念
- Anthropic Claude Code、OpenAI Codex CLI、Google Gemini CLI
