# CCG — Code Change Guardian

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/Shell-Bash%203.2%2B-green.svg)]()
[![Models](https://img.shields.io/badge/Models-25%2B-purple.svg)]()

> **CCG (Code Change Guardian)** is a multi-model code review and Git workflow automation system.
> Two independent AI model families guard every change across **Review · Commit · Merge · Push** —
> divergence-aware review, risk-aware model routing, AI merge-conflict resolution, and a pre-push gate,
> from the working tree to the remote.

CCG runs two independent models in parallel on each diff and lets Claude synthesize their findings. When they **agree**, signal is low; when they **diverge**, that's where humans should focus. Beyond review it adds a zero-LLM commit gate, AI-powered merge-conflict resolution, and a graphical pre-push scorecard — with a JSONL ledger that makes every review reusable.

**Other languages**: [简体中文](docs/README.zh-CN.md) · [日本語](docs/README.ja.md) · [한국어](docs/README.ko.md)

---

## Table of Contents

- [Why CCG](#why-ccg)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [The 4 Stages](#the-4-stages)
- [Model Strategy](#model-strategy)
- [Configuration](#configuration)
- [Architecture](#architecture)
- [Documentation](#documentation)

---

## Why CCG

CCG guards the entire path from working tree to remote — not just the review step. Each stage targets a specific pain point:

| Problem | CCG's Answer |
|---|---|
| Single-model review has blind spots | Two independent model families review in parallel — surface where they **disagree** |
| One-size-fits-all model wastes money / quality | Risk-aware auto-routing: cheap for low-risk, premium for critical |
| Merge conflicts are tedious and error-prone | **AI conflict resolution with Bailian as primary** — multiple safety guards, never silently drops code |
| Push decisions lack context | Stage 4 produces a **graphical quality scorecard** before push |
| Reviews aren't reusable | JSONL ledger captures every review, queryable by path |

---

## Installation

### npm 安装（推荐）

```bash
npm install -g @mcgrapeng/ccg
```

### 从源码安装

```bash
git clone https://github.com/mcgrapeng/ccg.git
cd ccg
npm link
```

### 验证安装

```bash
ccg --version
ccg doctor        # 检查环境配置
```

**环境要求:**
- `bash 3.2+`, `git`, `curl`, `jq`
- Node.js >= 16

---

## Configuration

CCG supports two configuration methods (config file takes priority over environment variables):

### Method 1: Config File (Recommended)

One-time setup, permanent effect:

```bash
# Initialize config file
ccg config init

# Set API keys (pick one or more)
ccg config set DEEPSEEK_API_KEY sk-xxx
ccg config set KIMI_API_KEY sk-xxx
ccg config set BAILIAN_API_KEY sk-xxx
ccg config set ANTHROPIC_API_KEY sk-ant-xxx

# Set default provider (optional)
ccg config set CCG_PROVIDERS deepseek

# View all config
ccg config list

# Edit config file directly
ccg config edit
```

Config file location: `~/.config/ccg/config`

### Method 2: Environment Variables

```bash
# Set in ~/.bashrc or ~/.zshrc
export DEEPSEEK_API_KEY="sk-xxx"
export KIMI_API_KEY="sk-xxx"
```

**Priority:** Environment variables > Config file > Default values

**自定义 API 端点（支持第三方代理）:**
- `CCG_CODEX_BASE_URL` / `OPENAI_BASE_URL` — Codex / OpenAI 代理
- `CCG_CLAUDE_BASE_URL` / `ANTHROPIC_BASE_URL` — Claude / Anthropic 代理
- `CCG_GEMINI_BASE_URL` / `GEMINI_BASE_URL` — Gemini 代理
- `CCG_BAILIAN_BASE_URL` — 百炼代理

---

## Quick Start

```bash
# 1. Review your current changes
ccg review

# 2. Auto-commit if review gate passes
ccg commit "feat: add user auth"

# 3. Merge with AI conflict resolution
ccg merge main

# 4. Pre-push graphical analysis & decision
ccg push origin main

# Helper commands
ccg config           # Show current configuration
ccg models           # List all available models
```

### Skip Review Mode

For trivial changes (docs, typos) you can disable Stage 1 entirely:

```bash
# Skip review — commit becomes the first stage
export CCG_REVIEW=off

ccg commit "docs: fix typo"   # Auto git add + commits (no LLM)
ccg push origin main           # Push still works

# Re-enable later
unset CCG_REVIEW   # or: export CCG_REVIEW=on
```

The `CCG_REVIEW` switch accepts: `on` (default) / `off` / `0` / `false` / `disabled`.

---

## Complete Workflow

### Default Flow (Review enabled)

```
┌───────────────────────────────────────────────────────────────────────┐
│  Stage 1: ccg review                                  【3 LLM calls】 │
│  ─────────────────────                                                │
│   1. ccg_init           → mktemp workdir + paths                      │
│   2. ccg_diff_capture   → 4-level fallback (worktree / staged / ...)  │
│   3. ccg_risk_score     → Bailian LLM (fallback: rule engine)         │
│   4. Auto-pick CCG_MODE (cost/balanced/quality) by risk               │
│   5. Run any 2 providers in parallel (codex/gemini/bailian)           │
│   6. ccg_synthesize     → Claude meta-review                          │
│      → CLASSIFICATION: AGREEMENT / DIVERGENCE / BLINDSPOT             │
│      → VERDICT: merge / fix-required / discuss                        │
│   7. Persist state to <repo>/.git/ccg/last-review.json                │
└───────────────────────────────────────────────────────────────────────┘
                                  ↓
┌───────────────────────────────────────────────────────────────────────┐
│  Stage 2: ccg commit "msg"                            【0 LLM calls】 │
│  ─────────────────────────                                            │
│   1. git add -A               (auto-stage worktree; opt out via       │
│                                CCG_NO_AUTO_ADD=1)                     │
│   2. Read last-review.json    (refuses if missing)                    │
│   3. Compare staged diff hash with reviewed hash                      │
│      → mismatch? refuse and ask user to re-run 'ccg review'           │
│   4. Apply verdict:                                                   │
│      • merge        → ✅ commit                                       │
│      • discuss      → ⚠️ commit (or block if CCG_GATE_DISCUSS=block)  │
│      • fix-required → ❌ block                                        │
│   5. git commit -m "msg"                                              │
│   6. Delete state file (one-shot)                                     │
└───────────────────────────────────────────────────────────────────────┘
                                  ↓
┌───────────────────────────────────────────────────────────────────────┐
│  Stage 3: ccg merge <target>                       【on-demand LLM】 │
│  ───────────────────────────                                          │
│   1. Safety checks: clean tree, no detached HEAD, no mid-op           │
│   2. git fetch + sync local target with origin                        │
│   3. Create backup branch (ccg-backup/<target>-<ts>-<pid>-<rand>)     │
│   4. git checkout target + git merge --no-commit feature              │
│   5. For each conflict file:                                          │
│      a. classify (content / binary / submodule / symlink / ...)       │
│      b. parse <<<<<<< >>>>>>> blocks                                  │
│      c. AI resolution (Bailian → Claude → Codex+Gemini)               │
│      d. validate (no markdown fences, no conflict markers, non-empty) │
│      e. atomic file rewrite (mktemp + mv, preserve perms)             │
│      f. git add (only if resolved cleanly)                            │
│   6. git commit (if all clean) OR leave uncommitted (if needs-human)  │
│   7. Real-time progress: [3/12] src/auth.js ... ✅ resolved           │
└───────────────────────────────────────────────────────────────────────┘
                                  ↓
┌───────────────────────────────────────────────────────────────────────┐
│  Stage 4: ccg push <remote> <branch>                 【1 LLM call】  │
│  ──────────────────────────────────                                   │
│   1. Detect upstream + remote URL                                     │
│   2. Compute commits ahead / behind                                   │
│   3. List commits with quality markers (✓ conventional / ⚠ WIP)       │
│   4. Categorize files (💻 code / 🧪 tests / 📖 docs / ⚙️ config)      │
│   5. Detect sensitive files (.env / *.pem / credentials / ...)        │
│   6. ccg_risk_score on the push diff (Bailian LLM)                    │
│   7. Quality Scorecard (5 checks):                                    │
│      • conventional commit messages                                   │
│      • tests updated alongside code                                   │
│      • no sensitive files                                             │
│      • up to date with remote                                         │
│      • risk level acceptable                                          │
│   8. Recommendation: 🟢 READY / 🟡 CAUTION / 🔴 NOT RECOMMENDED       │
│   9. Decision prompt: y/n/d (diff)/l (log)                            │
│  10. git push (if y)                                                  │
└───────────────────────────────────────────────────────────────────────┘
```

### Skip-Review Flow (`CCG_REVIEW=off`)

```
┌───────────────────────────────────────────────────────────────────────┐
│  Stage 1: ccg review                                   【0 LLM calls】│
│  → ℹ️  Review stage is DISABLED — no-op                              │
└───────────────────────────────────────────────────────────────────────┘

┌───────────────────────────────────────────────────────────────────────┐
│  Stage 2: ccg commit "msg"                             【0 LLM calls】│
│  → 1. git add -A                                                      │
│  → 2. ⚠️  Review stage DISABLED — committing without review           │
│  → 3. git commit -m "msg"                                             │
└───────────────────────────────────────────────────────────────────────┘
                                  ↓
            (Stage 3 / Stage 4 unchanged from default flow)
```

---

---

## The 4 Stages

CCG is built around four stages. Each has a specific purpose, model strategy, and safety guarantees.

### Stage 1 — Code Review (`ccg review`)

**Purpose**: Identify bugs, security issues, and quality problems in your diff.

**Model strategy**:
- Runs **any 2 models in parallel** from different vendors
- **Default depends on mode**:
  - `cost`/`balanced`: two different-vendor Bailian models (e.g., `qwen-3.5-haiku` + `deepseek-v4-lite`)
  - `quality`: `codex + gemini` (CLI-based, independent)
- **🚫 Claude is STRICTLY FORBIDDEN in Stage 1** — it is reserved exclusively for the Synthesis step where it serves as the meta-reviewer with an independent perspective
- Models are selected by current `CCG_MODE` (see [Model Strategy](#model-strategy))

**`CCG_PROVIDERS` syntax** (Stage 1 only — max 2 parallel):
```bash
# quality mode default — codex + gemini (CLI-based, independent)
CCG_PROVIDERS="codex gemini"

# Same provider, two different models — e.g., 2 Bailian models in parallel
CCG_PROVIDERS="bailian:qwen-3.7 bailian:deepseek-v4"

# Mix providers with explicit model overrides (quality mode only)
CCG_MODE=quality CCG_PROVIDERS="codex:gpt-5.5 gemini:gemini-3.5-flash"

# Cost optimization — all domestic models
CCG_PROVIDERS="bailian:kimi-k2.6 bailian:glm-5.1"

# ❌ DO NOT do this — claude is rejected and ccg review will return error
# CCG_PROVIDERS="claude codex"
```

**Output**: Synthesis classified as one of:
- `AGREEMENT` — both reviewers flag same issues (high confidence)
- `DIVERGENCE` — reviewers contradict (needs human judgment)
- `BLINDSPOT` — one missed issues the other caught (highest signal)

**Pipeline**:
```
git diff → risk scoring → mode selection
   → parallel: [Codex review + Bailian review]
   → synthesize → AGREEMENT | DIVERGENCE | BLINDSPOT
```

**Safety guarantees**:
- Prompt injection defense (untrusted-content markers, per-call nonce)
- Diff size warning (>200KB may exceed context)
- Cleanup trap (Ctrl+C kills child processes)
- Partial-failure handling (1/2 success → continue with warning)

---

### Stage 2 — Auto Commit (`ccg commit`)

**Purpose**: Enforce that only reviewed code reaches git history — **without any extra LLM calls**.

**Model strategy**: 🚫 **No LLM calls in Stage 2**. Reuses Stage 1's synthesis verdict.

**How it works**:
1. **Auto-stage worktree** with `git add -A` (opt out via `CCG_NO_AUTO_ADD=1`)
2. Read state file from `<repo>/.git/ccg/last-review.json` (written by Stage 1)
3. Verify the staged diff hash matches the reviewed hash
4. Apply the recorded verdict (`merge` / `fix-required` / `discuss`)
5. `git commit -m "msg"`
6. Delete the state file (one-shot — next commit needs a fresh review)

**State file contents**:
```json
{
  "ts": "2026-05-29T11:30:00Z",
  "diff_hash": "acb9adaab6516b3e7fc66fed10dd8a8d",
  "diff_source": "worktree",
  "verdict": "merge",
  "classification": "AGREEMENT",
  "mode": "balanced"
}
```

**Verdicts**:
| Verdict | Action |
|---|---|
| `merge` | ✅ Commit allowed |
| `discuss` | ⚠️ Allowed by default (set `CCG_GATE_DISCUSS=block` to enforce) |
| `fix-required` | ❌ Commit blocked |

**Failure modes**:
| Scenario | Result |
|---|---|
| No prior review | ❌ Error: "Run 'ccg review' first" (or set `CCG_REVIEW=off` to skip) |
| Diff changed since review | ❌ Hash mismatch — re-run review |
| Bypass diff check | `CCG_COMMIT_FORCE=1 ccg commit ...` |
| Auto-stage disabled | `CCG_NO_AUTO_ADD=1 ccg commit ...` — caller must `git add` first |
| Review disabled | `CCG_REVIEW=off ccg commit ...` — skips state check entirely |

**Why no LLM in Stage 2?**

The original design ran 2 parallel models here for adversarial robustness — but `ccg review` already does that (2 models + Claude synthesis). Repeating it on commit doubles cost and latency without adding signal. Reusing Stage 1's verdict is faster, cheaper, and equally safe.

---

### Stage 3 — AI Merge (`ccg merge <target>`) ⭐ **Core Competitive Advantage**

**Purpose**: Resolve merge conflicts professionally and reliably.

**Model strategy** (3-tier fallback):
1. **Bailian** (primary) — Aliyun-hosted models (most reliable for code)
2. **Claude** (secondary) — direct Anthropic API
3. **Codex + Gemini** (tertiary) — parallel race
4. `NEEDS_HUMAN_DECISION` if all fail

**Conflict classification** (only `content` goes to AI):
| Kind | Handling |
|---|---|
| `content` | AI resolution |
| `binary` | NEEDS HUMAN |
| `submodule` | NEEDS HUMAN |
| `symlink` | NEEDS HUMAN |
| `delete_modify` | NEEDS HUMAN |
| `both_deleted` | NEEDS HUMAN |
| `added_one_side` | NEEDS HUMAN |
| `both_added` | NEEDS HUMAN |

**Pipeline**:
```
checkout target → backup branch → git merge --no-commit
  ↓ (for each conflict file)
  classify → parse <<<<<<< blocks
  → Bailian resolution
    ↓ (if failed)
    Codex + Gemini parallel
    ↓ (if both failed)
    NEEDS_HUMAN_DECISION
  → validate (no markdown fences, no conflict markers, non-empty)
  → atomic file rewrite (mktemp + mv, preserve permissions)
  → git add (if resolved)
  ↓
  commit (if all clean) | leave uncommitted (if any needs-human)
```

**Safety guarantees**:
- Backup branch created BEFORE merge (`ccg-backup/<target>-<timestamp>-<pid>-<rand>`)
- Aborts if working tree is dirty, detached HEAD, or mid-operation
- Rejects diverged remote
- Per-conflict nonce prevents OURS/THEIRS injection
- Validates resolved content (no markdown fences, no conflict markers, non-empty)
- Atomic file replacement (`mktemp` + `mv`)
- Preserves file permissions and refuses to write through symlinks
- **Never silently drops code** — fails to NEEDS_HUMAN
- Real-time progress: `[3/12] src/auth.js ... ✅ resolved`
- Limits max conflicts (default 50, override via `CCG_MERGE_MAX_CONFLICTS`)

---

### Stage 4 — Pre-Push Analysis (`ccg push <remote> <branch>`)

**Purpose**: Show a comprehensive, graphical report before pushing — let user decide informed.

**Model strategy**: Bailian LLM for risk scoring (falls back to deterministic rules).

**Report sections**:
```
╔══════════════════════════════════════════════════════════╗
║          🚀  CCG Pre-Push Analysis Report  🚀            ║
╚══════════════════════════════════════════════════════════╝

  📍 Branch / Remote / HEAD / Author / Time

  ┌─ Commit Summary ─────────────────────────────────────┐
  │  Ahead: N commit(s) / Behind: M commit(s)
  └──────────────────────────────────────────────────────┘

  📝 Commits with quality markers (✓ conventional / ⚠ WIP)

  ┌─ Code Changes ───────────────────────────────────────┐
  │  Files / Lines added / Lines removed + visual bar
  └──────────────────────────────────────────────────────┘

  📂 File Categories: 💻 Code / 🧪 Tests / 📖 Docs / ⚙️ Config

  🚨 SENSITIVE FILES DETECTED (.env, *.pem, credentials, ...)

  ┌─ Risk Assessment ────────────────────────────────────┐
  │  Score: 🔴 CRITICAL (85) — auth + payment
  │  [████████████████████████████████████████████]
  └──────────────────────────────────────────────────────┘

  📊 Push Quality Scorecard:
     ✅ Conventional commit messages
     ✅ Code changes accompanied by tests
     ❌ Sensitive files in changeset
     ✅ Up to date with remote
     ⚠️  High risk score — review carefully

  ┌─ Recommendation ─────────────────────────────────────┐
  │  🔴 NOT RECOMMENDED (3/5 checks passed)
  └──────────────────────────────────────────────────────┘

  ┌─ Decision ───────────────────────────────────────────┐
  │  y — push   |   n — cancel   |   d — view diff   |   l — view log
  └──────────────────────────────────────────────────────┘
```

**Quality checks**:
1. Conventional commit messages (`feat|fix|chore|...:`)
2. Test files updated alongside code
3. No sensitive files (`.env`, `*.pem`, `credentials`, etc.)
4. Up to date with remote (not behind)
5. Risk level acceptable (<80)

---

### One-Click Ship (`ccg ship [target] [msg]`)

**Purpose**: Combine review → commit → merge in a single command.

**Pipeline**:
1. `ccg review` — run full Stage 1 review
2. `ccg commit` — commit with review gate (only if verdict is `merge`)
3. `ccg merge <target>` — merge into target branch

**Usage**:
```bash
# Ship to main with auto-detected target
ccg ship

# Ship to specific branch
ccg ship main

# Ship with custom commit message
ccg ship main "feat: add user auth"
```

**When to use**: For rapid iteration when you want the full review-commit-merge pipeline in one command.

---

## Model Strategy

### Four Independent Providers

| Provider | API Path | Required Env | Custom Endpoint |
|---|---|---|---|
| `codex` | Codex CLI (calls OpenAI) | `codex` binary | `CCG_CODEX_BASE_URL` / `OPENAI_BASE_URL` |
| `claude` | Direct Anthropic API | `ANTHROPIC_API_KEY` or `CLAUDE_API_KEY` | `CCG_CLAUDE_BASE_URL` / `ANTHROPIC_BASE_URL` |
| `gemini` | Gemini CLI (calls Google) | `gemini` binary + `GEMINI_API_KEY` | `CCG_GEMINI_BASE_URL` / `GEMINI_BASE_URL` |
| `bailian` | Direct Aliyun Bailian API | `BAILIAN_API_KEY` | `CCG_BAILIAN_BASE_URL` |

### Three Modes

CCG auto-selects mode based on risk score, or you can force it via `CCG_MODE`.

| Risk Score | Auto Mode | Strategy |
|---|---|---|
| `< 30` | `cost` | Use cheap Bailian models everywhere |
| `30 – 70` | `balanced` | Mix of mid-tier models per provider |
| `> 70` | `quality` | Top-tier models per provider |

### Model Per Mode

| Mode | codex | claude | gemini | bailian |
|---|---|---|---|---|
| **`cost`** | `gpt-5-mini` | `claude-haiku-4-5` | `gemini-2.5-flash-lite` | `qwen-3.5-haiku` |
| **`balanced`** | `gpt-5.4` | `claude-sonnet-4-6` | `gemini-2.5-flash` | `qwen-3.6` |
| **`quality`** | `gpt-5.5` | `claude-opus-4-7` | `gemini-3.5-flash` | `qwen-3.7` |

### Per-Stage Model Usage

| Stage | Uses Models? | Which Models |
|---|---|---|
| **Diff Capture** | ❌ | Pure git ops |
| **Risk Score** | ✅ Bailian LLM | Falls back to rule engine |
| **Stage 1: Review** | ✅ **any 2 slots in parallel** | Default: codex + gemini. Same provider can run twice with different models (e.g., `bailian:qwen-3.7 bailian:deepseek-v4`) |
| **Synthesize** | ✅ 1 model | **Claude preferred** (reserved meta-reviewer) → fallback: codex → bailian → gemini |
| **Stage 2: Commit Gate** | ❌ **NO LLM** | Reuses Stage 1 synthesis verdict (zero extra cost) |
| **Stage 3: Merge Conflicts** | ✅ **3-tier fallback** | Bailian → Claude → Codex+Gemini |
| **Stage 4: Push Check** | ✅ Bailian LLM | Risk scoring only |

### Available Bailian Models

| Model | Tier | Input ¥/1M | Output ¥/1M | Notes |
|---|---|---|---|---|
| `qwen-3.7` | quality | 0.30 | 0.90 | Latest Qwen |
| `deepseek-v4` | quality | 0.35 | 1.05 | Top reasoning |
| `kimi-k2.6` | quality | 0.32 | 0.96 | Long context |
| `glm-5.1` | quality | 0.28 | 0.84 | Multimodal |
| `qwen-3.6` | balanced | 0.25 | 0.75 | |
| `mimo-v2.5-pro` | balanced | 0.22 | 0.66 | |
| `qwen-3.6-plus` | balanced | 0.20 | 0.60 | |
| `qwen-3.5-sonnet` | balanced | 0.15 | 0.45 | |
| `deepseek-v4-lite` | balanced | 0.18 | 0.54 | |
| `kimi-k2.6-lite` | balanced | 0.16 | 0.48 | |
| `glm-5.1-lite` | balanced | 0.14 | 0.42 | |
| `mimo-v2.5` | cost | 0.11 | 0.33 | |
| `qwen-3.5-haiku` | cost | 0.05 | 0.15 | Cheapest |

---

## Configuration

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| **Switches / Mode** | | |
| `CCG_MODE` | auto | `cost` / `balanced` / `quality` |
| `CCG_REVIEW` | `on` | Master switch: `on` / `off` (when off, `ccg review` is a no-op and `ccg commit` skips state check) |
| `CCG_PROVIDERS` | auto (depends on mode) | Providers for Stage 1 (max 2 parallel). quality: codex+gemini, cost/balanced: bailian pair. Claude is reserved for Synthesis by default. |
| **Provider models** | | |
| `CCG_CODEX_MODEL` | by mode | Override Codex model |
| `CCG_CLAUDE_MODEL` | by mode | Override Claude model |
| `CCG_GEMINI_MODEL` | by mode | Override Gemini model |
| `CCG_BAILIAN_MODEL` | by mode | Override Bailian model |
| `CCG_DEEPSEEK_MODEL` | by mode | Override DeepSeek model |
| `CCG_KIMI_MODEL` | by mode | Override Kimi model |
| `CCG_GLM_MODEL` | by mode | Override GLM model |
| `CCG_MINIMAX_MODEL` | by mode | Override MiniMax model |
| `CCG_MIMO_MODEL` | by mode | Override Mimo model |
| **API keys** | | |
| `BAILIAN_API_KEY` | — | Bailian (Aliyun) API key |
| `ANTHROPIC_API_KEY` / `CLAUDE_API_KEY` | — | Anthropic API key |
| `GEMINI_API_KEY` | — | Google Gemini API key |
| `DEEPSEEK_API_KEY` | — | DeepSeek official API key |
| `KIMI_API_KEY` | — | Kimi (Moonshot) official API key |
| `GLM_API_KEY` | — | GLM (Zhipu) official API key |
| `MINIMAX_API_KEY` | — | MiniMax official API key |
| `MIMO_API_KEY` | — | Mimo official API key |
| **Custom endpoints (proxies)** | | |
| `CCG_CODEX_BASE_URL` / `OPENAI_BASE_URL` | OpenAI | Codex / OpenAI proxy URL |
| `CCG_CLAUDE_BASE_URL` / `ANTHROPIC_BASE_URL` | api.anthropic.com | Claude proxy URL |
| `CCG_GEMINI_BASE_URL` / `GEMINI_BASE_URL` | Google | Gemini proxy URL |
| `CCG_BAILIAN_BASE_URL` | dashscope.aliyuncs.com | Bailian proxy URL |
| `CCG_DEEPSEEK_BASE_URL` | api.deepseek.com/v1 | DeepSeek official API URL |
| `CCG_KIMI_BASE_URL` | api.moonshot.cn/v1 | Kimi official API URL |
| `CCG_GLM_BASE_URL` | open.bigmodel.cn/api/paas/v4 | GLM official API URL |
| `CCG_MINIMAX_BASE_URL` | api.minimax.chat/v1 | MiniMax official API URL |
| `CCG_MIMO_BASE_URL` | — | Mimo official API URL (required) |
| **Timeouts / Parameters** | | |
| `CCG_CODEX_TIMEOUT` | 240 | Codex timeout (seconds) |
| `CCG_GEMINI_TIMEOUT` | 120 | Gemini timeout (seconds) |
| `CCG_BAILIAN_TIMEOUT` | 120 | Bailian timeout (seconds) |
| `CCG_CLAUDE_TIMEOUT` | 120 | Claude timeout (seconds) |
| `CCG_DEEPSEEK_TIMEOUT` | 120 | DeepSeek timeout (seconds) |
| `CCG_KIMI_TIMEOUT` | 120 | Kimi timeout (seconds) |
| `CCG_GLM_TIMEOUT` | 120 | GLM timeout (seconds) |
| `CCG_MINIMAX_TIMEOUT` | 120 | MiniMax timeout (seconds) |
| `CCG_MIMO_TIMEOUT` | 120 | Mimo timeout (seconds) |
| `CCG_BAILIAN_TEMP` | 0.7 | Bailian temperature |
| `CCG_BAILIAN_MAX_TOKENS` | 4096 | Bailian max tokens |
| `CCG_BAILIAN_RETRIES` | 3 | Bailian retry count |
| `CCG_CLAUDE_RETRIES` | 3 | Claude retry count |
| **Gate / Commit** | | |
| `CCG_GATE_OFFLINE` | 0 | Set to 1 to skip Stage 2 review (legacy gate) |
| `CCG_GATE_DISCUSS` | allow | Set to `block` to block discuss verdict |
| `CCG_NO_AUTO_ADD` | 0 | Stage 2: skip auto `git add -A`, use only what's already staged |
| `CCG_COMMIT_FORCE` | 0 | Stage 2: bypass diff-hash check (force commit even if diff changed) |
| `CCG_AUTOCOMMIT_ALL` | 0 | Auto-commit all changes (including untracked) |
| `CCG_AUTOCOMMIT_DRY_RUN` | 0 | Dry run mode for autocommit |
| `CCG_DIFF_CACHED_ONLY` | 0 | Only use cached diff |
| **Merge** | | |
| `CCG_MERGE_DRY_RUN` | 0 | Stage 3: resolve but don't commit |
| `CCG_MERGE_NO_AI` | 0 | Stage 3: skip AI resolution |
| `CCG_MERGE_NO_FETCH` | 0 | Stage 3: skip remote fetch |
| `CCG_MERGE_MAX_CONFLICTS` | 50 | Stage 3: max conflict files |
| `CCG_MERGE_KEEP_BACKUP` | 0 | Stage 3: keep backup branch after success |
| **Cache / Ledger / Reports** | | |
| `CCG_NO_CACHE` | 0 | Disable prompt cache |
| `CCG_CACHE_TTL_HOURS` | 24 | Prompt cache TTL |
| `CCG_CACHE_DIR` | XDG default | Custom cache directory |
| `CCG_MAX_PROMPT_KB` | 100 | Max prompt size in KB |
| `CCG_USAGE_LOG` | XDG default | Custom usage log path |
| `CCG_LEDGER_LOG` | XDG default | Custom ledger log path |
| `CCG_LEDGER_MAX_LINES` | 10000 | Max ledger lines before rotation |
| `CCG_NO_HISTORY` | 0 | Disable review history injection |
| `CCG_HISTORY_MAX` | 3 | Max historical reviews to inject |
| `CCG_NO_REPORT` | 0 | Disable report persistence |
| `CCG_REPORT_DIR` | .ccg/reports | Custom report directory |
| `CCG_KEEP_ARTIFACTS` | 0 | Keep workdir for debugging |
| **Other** | | |
| `CCG_ALLOW_SAME_VENDOR` | 0 | Allow same vendor in Stage 1 slots |
| `CCG_SYNTH_PROVIDER` | auto | Override synthesizer provider |
| `CCG_RISK_LLM` | 0 | Enable LLM-based risk scoring |

### Usage Examples

```bash
# Force quality mode for a critical review
CCG_MODE=quality ccg review

# Use only Bailian (offline-friendly for China)
CCG_PROVIDERS="bailian" ccg review

# Mix providers — codex + claude (requires quality mode)
CCG_MODE=quality CCG_PROVIDERS="codex claude" ccg review

# Specific Bailian model
CCG_BAILIAN_MODEL=deepseek-v4 ccg review

# Use DeepSeek official API
DEEPSEEK_API_KEY="sk-xxx" CCG_PROVIDERS="deepseek" ccg review

# Use Kimi (Moonshot) official API
KIMI_API_KEY="sk-xxx" CCG_PROVIDERS="kimi" ccg review

# Use GLM (Zhipu) official API
GLM_API_KEY="xxx.xxx" CCG_PROVIDERS="glm" ccg review

# Use MiniMax official API
MINIMAX_API_KEY="xxx" CCG_PROVIDERS="minimax" ccg review

# Use Mimo official API (requires custom base URL)
MIMO_API_KEY="sk-xxx" CCG_MIMO_BASE_URL="https://api.mimo.com/v1" CCG_PROVIDERS="mimo" ccg review

# Mix independent providers (different vendors)
DEEPSEEK_API_KEY="sk-xxx" KIMI_API_KEY="sk-xxx" CCG_PROVIDERS="deepseek kimi" ccg review

# Use OpenAI through proxy (e.g., for China)
CCG_CODEX_BASE_URL="https://your-proxy.com/v1" ccg review

# Use Claude through proxy (e.g., third-party gateway)
CCG_CLAUDE_BASE_URL="https://tokensolo.com" ccg review

# Dry-run merge (resolve but don't commit)
CCG_MERGE_DRY_RUN=1 ccg merge main

# Skip AI merge resolution (just detect conflicts)
CCG_MERGE_NO_AI=1 ccg merge main
```

---

## Architecture

```
ccg/
├── ccg                              # Entry point (4-line delegator)
├── ccg.sh                           # Core engine (~3000 lines)
│   ├── _ccg_xdg_* / _ccg_vcs_*     # XDG paths + git abstraction
│   ├── ccg_init / ccg_preflight    # Workdir setup
│   ├── ccg_diff_capture            # 4-level diff fallback
│   ├── ccg_risk_score              # Bailian LLM + rule engine
│   ├── ccg_codex / ccg_gemini      # Provider runners (with custom endpoint support)
│   ├── ccg_claude / _ccg_claude_retry  # Direct Anthropic API (with custom endpoint)
│   ├── _ccg_bailian_retry          # Bailian with retry/backoff
│   ├── ccg_synthesize              # AGREEMENT/DIVERGENCE/BLINDSPOT
│   ├── ccg_precommit_gate          # Stage 2 commit gate
│   └── ccg_merge                   # Stage 3 AI merge (Bailian → Claude → Codex+Gemini)
│       ├── _ccg_classify_conflict  # content/binary/submodule/...
│       ├── _ccg_parse_conflicts    # extract <<<<<<<>>>>>>> blocks
│       ├── _ccg_resolve_one_conflict  # 3-tier AI resolution
│       └── _ccg_apply_resolutions  # atomic file rewrite
├── ccg-bailian-models.sh           # 15-model Bailian registry
├── ccg-bailian-integration.sh      # Bailian API call helpers
├── ccg-multi-provider.sh           # 4-provider orchestration
├── ccg-workflow.sh                 # 4-stage workflow entry points
└── ccg.md                          # Claude Code slash command spec

docs/
├── README.zh-CN.md / .ja.md / .ko.md    # Translations
├── ARCHITECTURE.md (+ 3 translations)   # Deep architecture
└── CHANGELOG.md                         # Version history
```

### Storage (XDG-compliant)

| Path | Content |
|---|---|
| `$XDG_DATA_HOME/ccg/usage.log` | Token usage + cost log |
| `$XDG_DATA_HOME/ccg/ledger.jsonl` | Per-review JSONL ledger |
| `$XDG_CACHE_HOME/ccg/cache/` | Prompt hash → result cache (24h TTL) |
| `$XDG_CONFIG_HOME/ccg/` | User config |

Legacy `~/.ccg/*` auto-migrated on first run.

---

## Documentation

- [Architecture deep-dive](docs/ARCHITECTURE.md) ([中文](docs/ARCHITECTURE.zh-CN.md) · [日本語](docs/ARCHITECTURE.ja.md) · [한국어](docs/ARCHITECTURE.ko.md))
- [Capabilities reference](docs/CAPABILITIES.md) — full feature inventory grounded in the source (中文)
- [Changelog](docs/CHANGELOG.md)
- [Slash command spec](ccg.md) — Claude Code `/ccg` command

---

## License

MIT
