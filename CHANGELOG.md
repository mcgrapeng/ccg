# Changelog

All notable changes to /ccg.

## [3.0.0] — 2026-05-23

Repositioning: from "multi-model review tool" to **"code divergence detector"**. Three structural pillars added; product opinion sharpened. 99-test regression (stable across 3 consecutive runs).

### Identity shift
**Before (v2):** "Get multi-model second opinions, see consensus + disagreement + actions."
**After (v3):** "Surface where Codex and Gemini *disagree* — that's where you actually need to make a call. Agreement is low-signal; divergence is the gold."

This is a category change. v3 deliberately downgrades the AGREEMENT section (one-liners only) and elevates DIVERGENCE (full expansion + `NEEDS HUMAN DECISION` markers).

### Added — Pillar 1: Divergence Engine
- Structured `[FINDING]…[/FINDING]` prompt protocol; both reviewers must conform
- Three-section synthesis output: `AGREEMENT (N) / DIVERGENCE (M) / BLINDSPOT (≤2)`
- `VERDICT` line: merge | fix-required | discuss
- `NEEDS HUMAN DECISION` is an explicit signal, not implied

### Added — Pillar 2: Risk-Aware Routing
- `ccg_risk_score <diff_file>` — deterministic 0..100+ scoring
  - Path signals: auth/payment/migration/crypto/security/infra/ci (+15..+40)
  - Body signals: shell exec/SQL interp/fs delete/privilege ops (+5..+30)
  - Size signals: lines and files-changed (+5..+25)
  - Docs-only subtraction (-40)
- Auto mode selection: <20 cost, <60 balanced, ≥60 quality
- Manual `CCG_MODE=` override always wins
- Outputs reason string for full transparency: `auth+35 sql_interp+30 size>300+15`
- Pure rules, zero LLM cost, social-PR friendly

### Added — Pillar 3: Review Ledger
- `ccg_ledger_record <workdir>` — append JSONL row to `~/.ccg/ledger.jsonl`
  - Fields: ts, repo, branch, sha, mode, risk, files, lines, paths[], synthesis (redacted, ≤400 chars)
- `ccg_ledger_query [path-substring]` — search prior reviews
- `CCG_LEDGER_LOG` env override
- Synthesis excerpt runs through `_ccg_redact` before write (secret hygiene)

### Fixed — diff capture deep gap
- Old behavior: `git diff HEAD` only → empty after commit
- New 4-level fallback: `worktree → staged → upstream:@{u}…HEAD → origin/HEAD…HEAD`
- Reports `CCG_DIFF_SOURCE=<level>` so caller knows what scope was captured
- Resolves "I committed and now /ccg sees nothing" footgun

### Changed
- Default `CCG_MODE=auto` (was `balanced`); auto uses risk score
- `ccg_init` now also exposes `CCG_SYNTHESIS_FILE` and `CCG_RISK_FILE` paths
- Dispatch subcommands added: `risk_score`, `ledger_record`, `ledger_query`

### Tests
- 13 new test cases (13.1 - 13.13) covering all three pillars + diff fallback
- All 99 tests pass; 31s runtime; stable across consecutive runs

## [2.0.0] — 2026-05-23

Major refactor based on honest self-critique: drop low-value features, add high-leverage ones.
86-test regression (stable across 10 consecutive runs).

### Removed
- **Pre-execution cost estimate** (`ccg_estimate`). Estimating output tokens by assumption produced 3-5× wrong predictions, misleading users. Post-execution `ccg_actual` remains — it uses real byte counts.
- **Asymmetric prompt split** (codex=architecture, gemini=UX). It was pure intuition with no evidence. v2 sends the **same prompt to both providers** — training-data differences create natural diversity.
- `ccg_mode_resolve` public subcommand (resolution is now internal/silent)
- `CCG_USD_CNY_RATE`, `CCG_OUTPUT_TOKENS_ESTIMATE`, `CCG_TOKEN_CHARS_RATIO` knobs (no one tuned them)

### Added
- **Auto `git diff` mode**: naked `/ccg` (no args) captures `git diff HEAD` and runs a pre-commit triangulated review. One-keystroke workflow.
- `ccg_diff_capture <out_file>` — captures `git diff HEAD`, falls back to `--cached`, returns `CCG_DIFF_OK/FAIL`
- **24h prompt-hash cache** keyed by SHA-256(model + prompt). Same prompt + same model → cached result, $0.00 cost. Iterating on the same code saves 90%+ on repeat calls.
- `CCG_CACHE_DIR` (default `~/.ccg/cache`) and `CCG_CACHE_TTL_HOURS` (default 24)
- `CCG_NO_CACHE=1` opt-out per-call
- **Usage log** at `~/.ccg/usage.log` (TSV: timestamp, provider, model, in_tokens, out_tokens, USD, cached). Only successful calls logged. Override path via `CCG_USAGE_LOG`.
- `ccg_usage [--this-month|--all|--since=YYYY-MM]` aggregates spend by provider with cache-hit count
- **Prompt size guard**: `CCG_MAX_PROMPT_KB=100` default. Hard reject prompts above this. Prevents the "I piped my whole repo and got a $5 bill" footgun.
- New dispatch subcommands: `diff_capture`, `usage`, `actual`

### Fixed
- Test suite now isolates cache via `CCG_CACHE_DIR` (not `HOME`), so test runs no longer break codex/gemini auth lookup
- Mock-mode test helpers always set `CCG_NO_CACHE=1` so failure-mode tests can't be masked by an earlier success-mode cache entry

## [1.0.0] — 2026-05-22

First production-ready release.

### Added
- `CCG_MODE=cost|balanced|quality` for model selection
- `CCG_CODEX_MODEL`/`CCG_GEMINI_MODEL` explicit overrides
- `ccg_codex` passes `-m <model>` when set
- LICENSE (MIT), CHANGELOG, scripts/install.sh
- 86-test regression in `tests/test_ccg.sh`

### Fixed
- **CRITICAL**: pure-bash timeout fallback lost stdin in async children. Real Codex/Gemini stdin delivery now works in all bash modes via explicit `<&0`.
- Timeout polling granularity: 1s → 0.1s + wall-clock deadline for sub-second responsiveness.
- Orphan sweep threshold: 60min → 1440min (24h).
- `eval`-safety for any printed shell-meta in mode descriptions.

## [0.x] — pre-release

Initial two-file plugin (commands/ccg.md + commands/ccg.sh).
