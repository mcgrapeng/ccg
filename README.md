# `/ccg` — Code Divergence Detector

[![Tests](https://img.shields.io/badge/tests-99%20passing-brightgreen.svg)]()
[![npm](https://img.shields.io/npm/v/@mcgrapeng/ccg.svg)](https://www.npmjs.com/package/@mcgrapeng/ccg)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**English** ｜ [简体中文](README.zh-CN.md) ｜ [日本語](README.ja.md) ｜ [한국어](README.ko.md)

> **Not a "better code review tool." A code divergence detector.**
> Most AI review tools chase consensus. `/ccg` does the opposite: it runs Codex (OpenAI) and Gemini (Google) in parallel on the same diff, then has Claude **surface where they disagree** — because that's where you, the human, actually need to make a call. Agreement is low-signal; divergence is the gold.

---

## The thesis

| Existing AI review tools | `/ccg` |
|---|---|
| Single model, single perspective | Two independent model families (different training data) |
| Output is a long review report | Output is a **divergence map** |
| You skim "everything looks fine" | You see "Codex flagged X, Gemini disagreed, NEEDS HUMAN DECISION" |
| Pre-commit hook style ("approve or block") | Triage tool ("here are the 2 things to actually think about") |

This positioning is unique. We are not aware of another OSS tool whose **stated product goal is to surface AI disagreement** rather than to give an answer.

---

## The three pillars

### Pillar 1 — Divergence Engine
Same prompt to both Codex and Gemini, structured `[FINDING]` format. Claude's synthesizer outputs three sections:

```
AGREEMENT (N)    — both flagged → low-signal, one-liner each
DIVERGENCE (M)   — judgment differs → expanded, ★ NEEDS HUMAN DECISION
BLINDSPOT (≤2)  — neither saw, Claude suspects → use sparingly
```

Agreement section is *deliberately* short. The product opinion: if both AI reviewers agreed, your single-source Claude probably would too — that's not new information. DIVERGENCE is the value.

### Pillar 2 — Risk-Aware Auto Routing
You should not have to pick `cost`/`balanced`/`quality` manually. `ccg_risk_score` looks at the diff and scores it deterministically (no LLM in this layer):

| Signal | Weight |
|---|---|
| Path matches `auth/payment/migration/crypto/security` | +25..+40 |
| Body contains `exec/eval/spawn` or SQL+interp | +20..+30 |
| Diff > 600 lines | +25 |
| Files > 8 | +10 |
| Docs-only changes | **-40** |

Score < 20 → cost. < 60 → balanced. ≥ 60 → quality. Manual override always wins.

The scoring is **transparent, zero-cost, and PR-able** — anyone can tune weights.

### Pillar 3 — Review Ledger
Every review appends one JSONL row to `$XDG_DATA_HOME/ccg/ledger.jsonl` (fallback `~/.local/share/ccg/ledger.jsonl`; legacy `~/.ccg/` auto-migrated):

```json
{"ts":"2026-05-22T18:35:06Z","repo":"/path","branch":"feat-x","sha":"91c16ec",
 "mode":"quality","risk":60,"files":1,"lines":"+5-0","paths":["auth/login.go"],
 "synthesis":"divergence on constant-time compare; NEEDS HUMAN DECISION..."}
```

Use it:

```bash
ccg_ledger_query                    # last 5 reviews
ccg_ledger_query "src/auth"         # how many times has this path been reviewed?
```

Front-loads zero value. After 50 reviews it becomes structural memory that no stateless tool can replicate.

---

## Install

Pick one. Both install the `/ccg` slash command into `~/.claude/commands/`.

### Option 1 — npm (recommended)

```bash
npx @mcgrapeng/ccg install        # one-time, no global pollution
# or
npm i -g @mcgrapeng/ccg && ccg install
```

### Option 2 — curl one-liner (no Node required)

```bash
curl -fsSL https://raw.githubusercontent.com/mcgrapeng/ccg/main/scripts/curl-install.sh | bash
```

### Then install the AI CLIs

```bash
npm i -g @openai/codex @google/gemini-cli
echo 'export GEMINI_API_KEY="<your-key>"' >> ~/.zshenv
```

Verify:

```bash
npx @mcgrapeng/ccg doctor         # or:  ccg doctor
```

Open a new Claude Code session and try `/ccg`.

## Usage

```bash
# Auto-mode: capture git diff → risk-score → run → synthesize → log
/ccg

# Explicit task (skips risk-score, uses CCG_MODE if set)
/ccg evaluate the lock-free queue implementation in src/queue.ts

# Force a mode
CCG_MODE=quality /ccg

# Force a specific model
CCG_CODEX_MODEL=o3 /ccg

# Query history
source ~/.claude/commands/ccg.sh
ccg_usage --this-month
ccg_ledger_query "src/payment"
```

## The diff capture is smart now

`/ccg` falls through 4 sources, in order:

| Source | When it kicks in |
|---|---|
| `worktree` | Uncommitted changes vs HEAD |
| `staged` | `git add`'d but not committed |
| `upstream:<branch>` | Worktree clean, but branch ahead of `@{u}` (committed-not-pushed) |
| `origin-head` | No upstream set, but `origin/HEAD` exists |

The selected source is reported as `CCG_DIFF_SOURCE` so you always know what's being reviewed. **Committing your work no longer hides it from `/ccg`**.

## Cost transparency

Pricing snapshot 2026-05 (USD per 1M tokens, official API):

| Mode | Codex | Gemini | Typical cost per call¹ |
|---|---|---|---|
| `cost`     | gpt-5-nano   | gemini-2.5-flash-lite | ~$0.0007 |
| `balanced` | gpt-5-mini   | gemini-2.5-flash      | ~$0.0046 |
| `quality`  | gpt-5        | gemini-2.5-pro        | ~$0.0440 |

¹ For a 1500-char prompt + ~500 output tokens. Cache hits: $0.0000.

After each call, `/ccg` prints actual cost based on real byte counts. `ccg_usage --this-month` for cumulative.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `CCG_MODE` | `auto` | `auto` / `cost` / `balanced` / `quality`. `auto` uses risk score. |
| `CCG_CODEX_MODEL` | (mode default) | Override codex model |
| `CCG_GEMINI_MODEL` | (mode default) | Override gemini model |
| `CCG_CODEX_TIMEOUT` | `240` | Codex hard timeout (s) |
| `CCG_GEMINI_TIMEOUT` | `120` | Gemini hard timeout (s) |
| `CCG_NO_CACHE` | `0` | `1` = bypass prompt-hash cache |
| `CCG_CACHE_TTL_HOURS` | `24` | Cache TTL |
| `CCG_CACHE_DIR` | `$XDG_CACHE_HOME/ccg/cache` | Cache directory |
| `CCG_MAX_PROMPT_KB` | `100` | Prompt size hard limit |
| `CCG_USAGE_LOG` | `$XDG_DATA_HOME/ccg/usage.log` | Usage log path |
| `CCG_LEDGER_LOG` | `$XDG_DATA_HOME/ccg/ledger.jsonl` | Ledger path |
| `CCG_KEEP_ARTIFACTS` | `0` | `1` = preserve workdir for debugging |

## Production-grade properties (99 tests verify these)

| Property | How |
|---|---|
| **Concurrency safe** | mktemp per call; mode 700; never collides |
| **Portable timeout** | Falls back to pure-bash with sub-second polling + wall-clock deadline |
| **Stdin preservation** | Explicit `<&0` on backgrounded child — fixes the bash async-stdin-to-devnull footgun |
| **Path-traversal safe cleanup** | Rejects relative / `..` / symlink / non-`ccg.` basenames |
| **Orphan sweep** | 24h conservative threshold, UID-scoped |
| **Secret redaction** | 7 patterns: sk-/AIza/Bearer/JWT/ghp_/AKIA/Slack + URL query strings |
| **Graceful degradation** | Any CLI fail → keep going with remaining model + Claude |
| **Cache safety** | Failed calls NOT cached; cache keyed by (prompt SHA-256 + model); auto-expire TTL |
| **Usage accuracy** | Only successful calls logged with token counts + USD; cache hits logged as $0.00 |
| **Prompt size guard** | Default 100KB cap prevents accidental $5 reviews |
| **Diff capture 4-level fallback** | worktree → staged → upstream → origin-head, with `CCG_DIFF_SOURCE` reporting |
| **Risk scoring transparency** | Pure rules, returns reason string (e.g. `auth+35 sql_interp+30 size>300+15`) |
| **Ledger JSON validity** | Every row passes `json.loads`; synthesis excerpt redacted before write |
| **Dispatch guard** | `BASH_SOURCE[0] == $0` test prevents sourced-with-args misfire |

## Testing

```bash
bash tests/test_ccg.sh                # 99 tests, ~31s
REAL_CLI=1 bash tests/test_ccg.sh     # +2 live API tests (incurs cost)
```

## What `/ccg` is NOT

- **Not a replacement for `/review` or `/code-review`** — those are deep-context single-source. Use `/ccg` when you want non-Claude perspectives on a risky change.
- **Not a conversation tool** — each call is fresh; no `continuation_id`.
- **Not streaming** — both reviewers run to completion before synthesis.
- **Not multi-host** — Claude Code only. For Cursor/Cline, see [zen-mcp-server](https://github.com/BeehiveInnovations/zen-mcp-server).
- **Not a security scanner** — divergence detection ≠ static analysis. Pair with Semgrep/CodeQL.

## Comparison to existing tools

| Tool | Identity | Output | Divergence focus? |
|---|---|---|---|
| GitHub Copilot Reviews | Single-model PR review | Inline comments | ❌ |
| Cursor `/review` | Single-model inline | Suggestions | ❌ |
| zen-mcp-server | Multi-model MCP gateway | Generic chat | ❌ (consensus) |
| Aider `/review` | Single-model | Edit-aware suggestions | ❌ |
| **`/ccg`** | **Multi-source divergence detector** | **AGREEMENT / DIVERGENCE / BLINDSPOT** | **✅ core product** |

## When `/ccg` shines

- **Risky changes**: auth, payment, migration, crypto — exactly the cases where you want "did the OTHER model see what mine missed?"
- **Pre-merge PR review**: branch ahead of upstream → `/ccg` automatically reviews the branch delta
- **Solo dev safety net**: no human reviewer? `/ccg` is the closest thing to a second pair of eyes

## When `/ccg` is overkill

- Renaming a variable
- One-line typo fix
- README edits
- Routine refactor with strong test coverage

The risk router downgrades these to `cost` mode automatically (~$0.0007), but honestly: just commit and move on. `/ccg` earns its keep on the 5–10% of changes that matter.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

- [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) for the original `/ccg` concept
- Anthropic Claude Code, OpenAI Codex CLI, Google Gemini CLI
