# ccg — Code Divergence Detector

> A Claude Code slash command. Install once, type `/ccg` on a diff.

[![Tests](https://img.shields.io/badge/tests-99%20passing-brightgreen.svg)]()
[![npm](https://img.shields.io/npm/v/@mcgrapeng/ccg.svg)](https://www.npmjs.com/package/@mcgrapeng/ccg)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**English** ｜ [简体中文](README.zh-CN.md) ｜ [日本語](README.ja.md) ｜ [한국어](README.ko.md)　·　[Architecture →](docs/ARCHITECTURE.md)

---

## What

ccg runs **Codex (OpenAI)** and **Gemini (Google)** in parallel on the same diff, then has **Claude** surface where they disagree — because that's where a human actually needs to make a call.

Most AI review tools chase consensus. ccg does the opposite. Agreement is low-signal. Divergence is the gold.

## Why

Three things ccg gives you that no single-model review tool does:

**1. A second opinion that doesn't think like Claude.**
Codex and Gemini are trained on different data, so they catch different things. When they disagree on a change in `auth/login.go`, that's exactly the spot you should slow down.

**2. Cost telemetry built in.**
Codex/Gemini CLIs don't tell you what you spent. ccg logs every call, picks the cheapest sufficient model automatically (risk-aware routing), and caches identical prompts for 24h.

**3. A review history that survives across sessions.**
"What did the model say about `src/auth.ts` two weeks ago?" — ccg's append-only ledger answers that. No stateless tool can.

## Install

Pick one:

```bash
# npm (recommended)
npx @mcgrapeng/ccg install

# or curl one-liner, no Node
curl -fsSL https://raw.githubusercontent.com/mcgrapeng/ccg/main/scripts/curl-install.sh | bash
```

Then install the AI CLIs once:

```bash
npm i -g @openai/codex @google/gemini-cli
echo 'export GEMINI_API_KEY="<your-key>"' >> ~/.zshenv
```

Verify the install:

```bash
npx @mcgrapeng/ccg doctor      # check Codex / Gemini / API key
npx @mcgrapeng/ccg about       # see all 7 capability layers + runtime state
```

## Try it

Open Claude Code in any git repo with changes, type:

```
/ccg
```

ccg will:

1. Capture the active diff (worktree → staged → upstream → origin-head fallback)
2. Score risk, auto-pick `cost`/`balanced`/`quality` model
3. Run Codex + Gemini in parallel on the same prompt
4. Synthesize into three sections:

```
═══ AGREEMENT (N) ═══     Both flagged — low signal, one line each
═══ DIVERGENCE (M) ═══    ★ The whole point of ccg
                          - Codex: said X
                          - Gemini: said Y
                          - Claude verdict: ___ or NEEDS HUMAN DECISION
═══ BLINDSPOT (≤2) ═══   Neither saw it, Claude suspects — use sparingly
═══ VERDICT ═══          merge / fix-required / discuss
```

Then `ccg_ledger_record` writes one JSONL row. `ccg_cleanup` removes the workdir.

## Configure (defaults are usually fine)

Mode and model picks are automatic. Override only when needed:

```bash
CCG_MODE=quality /ccg          # force quality models on any diff
CCG_CODEX_MODEL=o3 /ccg        # override one model
CCG_NO_CACHE=1 /ccg            # skip 24h cache for this call
```

Every knob lives in [Architecture → §5 Extension points](docs/ARCHITECTURE.md#5-extension-points). Common ones:

| Variable | Default | Purpose |
|---|---|---|
| `CCG_MODE` | `auto` | `auto` / `cost` / `balanced` / `quality` |
| `CCG_CACHE_TTL_HOURS` | `24` | Cache TTL |
| `CCG_MAX_PROMPT_KB` | `100` | Per-call prompt size cap |

Cost reference (USD per call, after cache):

| Mode | Codex | Gemini | Typical cost |
|---|---|---|---|
| `cost`     | gpt-5-nano  | gemini-2.5-flash-lite | ~$0.0007 |
| `balanced` | gpt-5-mini  | gemini-2.5-flash      | ~$0.0046 |
| `quality`  | gpt-5       | gemini-2.5-pro        | ~$0.0440 |

See accumulated spend any time:

```bash
source ~/.claude/commands/ccg.sh
ccg_usage --this-month
```

## Not for

- IDEs other than Claude Code (try [zen-mcp-server](https://github.com/BeehiveInnovations/zen-mcp-server))
- Replacing static analysis (pair with Semgrep / CodeQL)
- Auto-running on every PR (ccg is a triage tool, not a bot)
- Streaming or multi-turn conversation

## Architecture & contributing

ccg is **7 layers**, only the top one is "divergence detection". The other six (cache, ledger, usage, risk routing, smart diff, safe CLI scheduling) each independently solve a real problem. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing anything in `ccg.sh`.

Tests:

```bash
bash tests/test_ccg.sh                # 99 regression tests, ~31s
REAL_CLI=1 bash tests/test_ccg.sh     # +2 live API tests (incurs cost)
```

## License & credits

MIT — see [LICENSE](LICENSE).

Built on [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode)'s original `/ccg` concept · Claude Code · OpenAI Codex CLI · Google Gemini CLI.
