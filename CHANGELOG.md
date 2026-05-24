# Changelog

All notable changes to /ccg.

## [3.2.0] — 2026-05-24

Closes the L6 loop: the ledger goes from write-only to bidirectional. Each `/ccg` now reads prior reviews on the touched files and injects them into the next prompt — recurring patterns and unresolved `fix-required` items no longer evaporate between sessions. 121-test regression (+10 new); safe drop-in upgrade from 3.1.0.

### Added — Ledger consumer (closes the moat loop)
- **`ccg_ledger_context <diff_file>`** — new public helper. Extracts touched paths from the diff, greps the ledger for JSON-quoted `"<path>"` matches (fixed-string, so `src/foo.ts` won't false-match `src/foobar.ts`), dedups, takes the last `CCG_HISTORY_MAX` (default 3) most-recent entries, and writes them as a structured Markdown block to `<workdir>/history.txt` for prompt embedding. Pure shell (grep + sed) — no extra LLM call, millisecond-level overhead.
- **`ccg.md` step 2.5** — new protocol step between `ccg_diff_capture` (L3) and `ccg_risk_score` (L5). Claude embeds `history.txt` into both Codex and Gemini prompts before the diff, so both reviewers see "what we already argued about on these files" as prior context.
- **New env knobs**:
  - `CCG_NO_HISTORY=1` — disable consumer (useful for "single-perspective baseline" reviews or debugging).
  - `CCG_HISTORY_MAX=<n>` — cap injected entries (default 3; larger N inflates prompt size).
- **Dispatch subcommand** `bash ccg.sh ledger_context <diff_file>` for standalone shell use.
- **Status sentinels** parallel to existing helpers:
  - `CCG_HISTORY_OK=<n>_matches_<max>_max` + `CCG_HISTORY_FILE=<path>`
  - `CCG_HISTORY_NONE=0_matches` (ledger exists but no path overlap)
  - `CCG_HISTORY_SKIPPED=<disabled|no-diff|no-ledger|no-paths-in-diff>`
  - `CCG_HISTORY_FAIL=<reason>`

### Fixed — cross-shell `local var` footgun (zsh)
- **Critical**: zsh treats `local var` (without `=`) as a *print* operation — it dumps the variable's current value to stdout. Declaring locals *inside* a loop body silently leaked iteration N-1's values into output files on machines where the user's default shell is zsh (i.e., when Claude Code's Bash tool inherits zsh as the underlying shell).
- Discovered during smoke-testing of `ccg_ledger_context`: iteration 2's `local ts sha mode ...` printed iteration 1's values into the rendered `history.txt`.
- Fix: hoist all loop-mutated locals once outside the while loop. Regression locked in by test 15.9 ("history.txt contains NO bash/zsh debug-leak lines").
- Architecture decision table updated with the rule: **inside loop bodies, `local var=` (with `=`) is mandatory** — bash treats `local var` and `local var=` identically, but zsh does not.

### Documentation
- `docs/ARCHITECTURE.md` — new "L6 consumer" subsection in §3 covering algorithm, value proposition, the zsh footgun, and knobs. Data-flow diagram (§4) updated to include the new step. Design-decision table (§7) gains a row about `local var=`. Moat section (§9) reframed: L6 = ledger + consumer (the consumer is what compounds the data within a session).
- 4-language sync: `docs/ARCHITECTURE.{zh-CN,ja,ko}.md` mirror all of the above.
- README.md "Why ccg" §3 (and all 3 mirrors) updated to mention the auto-injection behavior.
- `ccg.md` configuration table gains `CCG_NO_HISTORY` + `CCG_HISTORY_MAX` rows; troubleshooting table gains rows for `CCG_HISTORY_SKIPPED=no-ledger` and `CCG_HISTORY_NONE=0_matches`.

### Tests
- 10 new test cases (15.1 - 15.10):
  - Skip paths (disabled / no-ledger / no-diff / no-paths-in-diff)
  - NONE return on path-mismatch
  - History file write + content correctness (ts/sha/mode for matched entries only)
  - `CCG_HISTORY_MAX` enforcement
  - **15.9 zsh regression guard** — asserts `history.txt` contains no bare `ts=` / `sha=` / `synth=` lines at column 1 (would re-appear if a future contributor moves `local` declarations back inside the loop)
  - Dispatch subcommand exposed via `bash ccg.sh ledger_context`
- Suite total: 111 → 121, all passing. Runtime ~32s (unchanged).

### Compatibility
- Drop-in safe from 3.1.0. New behavior is enabled by default but degrades to a no-op when:
  - Ledger doesn't exist yet (first runs)
  - Current diff touches files no prior review covers
  - User sets `CCG_NO_HISTORY=1`
- No changes to existing function signatures. No changes to ledger record format (the consumer reads what `ccg_ledger_record` already writes).

## [3.1.0] — 2026-05-23

Documentation and discoverability release. No core behavior changes; safe drop-in upgrade from 3.0.0.

### Added
- **`ccg about` subcommand** — 7-layer capability probe. Shows what ccg can do in *this* environment (not what the README claims), with green/yellow/red status per layer, environment readiness checks (Codex CLI / Gemini CLI / GEMINI_API_KEY / git / slash command installation), XDG storage state (ledger entries, usage entries, cache size), and a quick-reference command palette.
  - Aliases: `ccg capabilities`, `ccg caps`
  - Use case: "I'm a new user / contributor — what is ccg actually doing on my machine right now?"
- **`docs/ARCHITECTURE.md`** — 387-line engineering reference for contributors and integrators. Documents the 7-layer architecture (L1 Safe CLI scheduling → L7 Divergence synthesis), each layer's purpose / problem / solution / "what breaks if you remove it", end-to-end data flow, extension points (signed contract for new risk rules / new LLM providers / new storage paths / pricing customization), invariants enforced by the test suite, and load-bearing design decisions that look weird at first glance.
- **4-language ARCHITECTURE translations**: `docs/ARCHITECTURE.zh-CN.md`, `docs/ARCHITECTURE.ja.md`, `docs/ARCHITECTURE.ko.md`. Cross-linked from each language's README.

### Changed
- **README fully rewritten** with a concrete bcrypt walkthrough — actual output (not placeholder mockups) showing how AGREEMENT / DIVERGENCE / BLINDSPOT sections render in practice. The example shows two real-world disagreement: should `bcrypt` be wrapped with `subtle.ConstantTimeCompare`? Claude synthesizes that Codex's recommendation would break the comparison entirely because bcrypt uses a fresh salt every call.
- **"When to use ccg" rewritten** — replaced the security-only framing (auth / payments / migrations / crypto) with judgment-difficulty framing. New trigger: *feeling*, not *domain*. Added cross-domain examples across social platforms, data/AI infra, frontend, API design, distributed systems, database, and security — emphasizing that divergence detection earns its cost on *any* change where two reasonable engineers might disagree.
- **README structure** restructured into three-part flow: What / Why-vs-alternatives / Install / Walkthrough — designed to answer "what does it do" and "what does the output mean" before diving into config.
- README v-prefix removed from H1 headings (no more "v3" branding in titles; version lives in CHANGELOG + npm).

### Internal
- `PROMO.md` added to `.gitignore` (marketing copy file, not part of npm package).

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
