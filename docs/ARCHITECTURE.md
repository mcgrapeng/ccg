# Architecture

> Audience: contributors and integrators. If you just want to use `ccg`, read [README.md](../README.md). If you want to **change ccg**, read this.
>
> This doc describes what `ccg.sh` and `bin/ccg.js` actually do. Cross-reference function names with `grep -n '^ccg_\|^_ccg_' ccg.sh` if anything looks off.

**English** ｜ [简体中文](ARCHITECTURE.zh-CN.md) ｜ [日本語](ARCHITECTURE.ja.md) ｜ [한국어](ARCHITECTURE.ko.md)

---

## 1. What ccg is

ccg is a **production-grade orchestrator for calling Codex + Gemini CLI from inside Claude Code**.

"Code divergence detector" is the [L7 product hook](#l7--divergence-synthesis-claude-side) layered on top of six lower layers — each of which independently solves a real engineering problem you'd otherwise hit when shelling out to LLM CLIs from a slash command.

> If you delete L7, ccg is still useful (cache, ledger, usage, risk routing).
> If you delete L1, ccg is unsafe.
> The product story sells L7. The engineering substance is L1–L6.

---

## 2. The 7 layers

```
┌─────────────────────────────────────────────────────────────────────────┐
│  L7  Divergence synthesis  (lives in ccg.md prompt, run by Claude)      │
│      AGREEMENT / DIVERGENCE / BLINDSPOT three-section output            │
├─────────────────────────────────────────────────────────────────────────┤
│  L6  Review ledger          ccg_ledger_record / ccg_ledger_query        │
│      JSONL append-only, grep-able, secret-redacted                      │
│      + ccg_persist_report  → <repo>/.ccg/reports/<sha>_<ts>.md          │
│      + ccg_ledger_context  → history.txt injected into next prompt      │
├─────────────────────────────────────────────────────────────────────────┤
│  L5  Risk-aware routing     ccg_risk_score                              │
│      Pure-rule scoring on diff → cost / balanced / quality              │
├─────────────────────────────────────────────────────────────────────────┤
│  L4  Usage telemetry        ccg_actual / ccg_usage / _ccg_log_usage     │
│      USD-aware, model-aware, month-aware                                │
├─────────────────────────────────────────────────────────────────────────┤
│  L3  Smart diff capture     ccg_diff_capture                            │
│      4-level fallback: worktree → staged → upstream → origin-head       │
├─────────────────────────────────────────────────────────────────────────┤
│  L2  Content-addressed cache _ccg_cache_lookup / _ccg_cache_store       │
│      SHA-256 prompt+model key · 24h TTL · failed calls NOT cached       │
├─────────────────────────────────────────────────────────────────────────┤
│  L1  Safe CLI scheduling    _ccg_run_with_timeout / _ccg_redact /       │
│      ccg_cleanup / _ccg_check_prompt_size / mktemp 700 isolation        │
├─────────────────────────────────────────────────────────────────────────┤
│  L0  VCS abstraction        _ccg_vcs_detect / _ccg_vcs_root /           │
│      _ccg_vcs_info / _ccg_svn_diff                                      │
│      git + SVN 1.7+ (svn diff --git → standard unified diff format)     │
│      + ccg_precommit_gate  → commit gate (exit 0/1 on verdict)          │
│      + ccg_install_hook / ccg_uninstall_hook                            │
└─────────────────────────────────────────────────────────────────────────┘

       ↑                                       ↑
   bin/ccg.js                            ~/.claude/commands/ccg.sh
   (Node CLI: install/about/doctor)      (Bash core, what Claude sources)
```

Each layer is callable in isolation. `bash -c 'source ccg.sh; ccg_risk_score diff.txt'` works without ever touching L7.

---

## 3. The 7 layers, in detail

### L1 — Safe CLI scheduling
**Problem:** Naively running `codex < prompt.txt` from a shell-out is unsafe in 5 distinct ways: no timeout, stdin gets redirected to `/dev/null` when backgrounded, API keys leak into logs, prompt size unbounded, temp dirs orphan on crash.

**Solution:**
- `_ccg_run_with_timeout` — bash 3.2+ portable timeout. Prefers `timeout` / `gtimeout`; falls back to pure-bash polling with wall-clock deadline. Critical line: explicit `<&0` on the backgrounded child to preserve stdin (bash's default async-job stdin redirect to `/dev/null` is a well-known footgun).
- `_ccg_redact` — 7 regex patterns: `sk-*`, `AIza*`, `Bearer *`, JWT-shaped tokens, `ghp_*`, `AKIA*`, Slack `xox[bpoas]-*`. Plus URL query-string values. Applied to every stderr captured + every ledger synthesis write.
- `ccg_cleanup` — rejects relative paths, `..`, symlinks, and non-`ccg.` basenames before `rm -rf`. Also UID-scoped orphan sweep with 24h conservative threshold.
- `_ccg_check_prompt_size` — 100KB default ceiling per call. Prevents the "I accidentally piped a 5MB diff and got billed $5" footgun.
- `ccg_init` — `mktemp -d` with mode 0700; never collides across concurrent invocations.

**Delete this layer:** ccg becomes a glorified `echo prompt | codex` wrapper that leaks secrets and orphans `/tmp`. Unshippable.

---

### L2 — Content-addressed cache
**Problem:** When debugging the same diff repeatedly (especially when iterating on ccg itself), you pay for the same prompt twice. There's no "this is identical to last call" notion in either codex CLI or gemini CLI.

**Solution:**
- Key = `sha256(prompt_contents) + model_id`. Identical prompt + same model = guaranteed hit.
- Value = the LLM's full output blob.
- TTL = 24h (configurable via `CCG_CACHE_TTL_HOURS`).
- **Failure isolation:** if a call returns `_FAIL=` or empty, it is **not** cached. Otherwise a transient 503 would poison the cache for 24h.
- Storage at `$XDG_CACHE_HOME/ccg/cache/`. Safe to `rm -rf` anytime — worst case you re-pay one call.

**Delete this layer:** debug-loop cost increases ~5×. Not unsafe, just expensive.

---

### L3 — Smart diff capture
**Problem:** `git diff` only shows uncommitted changes. The moment you `git commit`, `cursor /review` and similar tools see "nothing to review". But your branch ahead of upstream is *the most important review surface* — it's about to merge.

**Solution:** `ccg_diff_capture <out_file>` falls through 4 sources in order:

| Order | Source | Test |
|---|---|---|
| 1 | `worktree` | `git diff HEAD` produces non-empty output |
| 2 | `staged` | `git diff --cached` produces non-empty output |
| 3 | `upstream:<branch>` | `git rev-parse @{u}` resolves AND `git diff @{u}` non-empty |
| 4 | `origin-head` | `git rev-parse origin/HEAD` resolves AND `git diff origin/HEAD` non-empty |

The chosen source is exposed via `CCG_DIFF_SOURCE` so callers (Claude in L7) can label the review. Also returns `CCG_DIFF_FAIL=not-a-git-repo` or `=empty-diff` as explicit non-error sentinels for the protocol to handle.

**Delete this layer:** ccg silently loses the ability to review committed-but-unpushed work — the single most valuable review window.

---

### L4 — Usage telemetry
**Problem:** No LLM CLI tells you "you've spent $X this month." `gh copilot` doesn't, `codex` doesn't, `gemini` doesn't. Cost stays invisible until the billing email.

**Solution:**
- `ccg_actual <prompt> <result> <provider>` — measured AFTER the call. Reads real byte counts of the prompt + result, converts to tokens via `_ccg_tokens_from_chars` (`chars / 3.0` heuristic; off by ~15%), multiplies by `_ccg_price(model, direction)`, appends one line to `$XDG_DATA_HOME/ccg/usage.log`.
- `ccg_usage [--this-month|--all|--since=YYYY-MM]` — sums the log.
- **Cache hits log as $0.00** so usage stays accurate.
- **Failed calls don't log at all** — a 503 that returns nothing shouldn't count as $0.001 spent.

Format: `<iso_ts> <provider> <model> in=<n> out=<n> usd=<float>`. Plain text on purpose — `grep` and `awk` work.

**Delete this layer:** cost becomes folklore. You'll spend $30/month and have no idea on what.

---

### L5 — Risk-aware routing
**Problem:** `cost` / `balanced` / `quality` modes have a 60× price spread (≈$0.0007 vs ≈$0.0440 per call). Asking the user to pick every time is a UX disaster. Asking an LLM to self-pick creates a feedback loop. Neither is right.

**Solution:** `ccg_risk_score <diff_file>` is pure rule scoring — no LLM in this layer. Reads the diff and returns:

```
CCG_RISK_SCORE=72
CCG_RISK_MODE=quality
CCG_RISK_FILES=5
CCG_RISK_LINES=+340-12
CCG_RISK_REASONS=auth+40 sql_interp+30 size>300+15 docs_only-40
```

Rules in `ccg.sh:ccg_risk_score`:

| Signal | Weight | Detection |
|---|---|---|
| Path matches `auth\|payment\|migration\|crypto\|security` | +25..+40 | regex on file paths |
| Body contains `exec\|eval\|spawn` or `sql.*interp` | +20..+30 | regex on patch content |
| Hardcoded URL/host literals | +5 | regex |
| TODO/FIXME/HACK markers | +5 | regex |
| Diff > 600 lines | +25 | line count |
| Files > 8 | +10 | hunk count |
| Docs-only changes (`.md` / `.txt` / `.rst` only) | **-40** | path extensions |

**Thresholds:** `< 20 → cost`, `< 60 → balanced`, `≥ 60 → quality`.

**Why no LLM:** transparency, zero cost, PR-able weights. A community contributor can `sed -i 's/+40/+50/' ccg.sh` and submit a 1-line PR. With an LLM scorer, every routing decision becomes opaque.

**Delete this layer:** user has to set `CCG_MODE` manually every time, or always pays for `quality`.

---

### L6 — Review ledger
**Problem:** Every LLM CLI is stateless. "What did Codex say about `src/auth.ts` two weeks ago?" — no tool can answer.

**Solution:** `ccg_ledger_record <workdir>` appends one JSONL line per review to `$XDG_DATA_HOME/ccg/ledger.jsonl`:

```json
{"ts":"2026-05-22T18:35:06Z","repo":"/path","branch":"feat-x","sha":"91c16ec",
 "mode":"quality","risk":72,"files":1,"lines":"+5-0","paths":["auth/login.go"],
 "synthesis":"divergence on constant-time compare; NEEDS HUMAN DECISION..."}
```

The `synthesis` field is the first ~400 chars of Claude's combined verdict — long enough to be useful, short enough to grep through 1000 entries.

`ccg_ledger_query` operations:
- `ccg_ledger_query` — last 5 reviews.
- `ccg_ledger_query "src/auth"` — reviews touching this path fragment, with count + last 3 dates.

**Front-loads zero value.** After 50 reviews it becomes structural memory that no stateless tool can replicate — this is the long-term moat.

**Delete this layer:** ccg becomes 100% stateless. Every review starts from scratch. The L7 product story still works, but the long-term differentiation is gone.

#### L6 consumer — `ccg_ledger_context` (closes the loop)

Without a consumer, the ledger is a write-only diary — every review starts from scratch even though the ledger holds the answer to "what did we already argue about on this file?". `ccg_ledger_context <diff_file>` is the bidirectional half:

1. Extract unique paths from the diff (`diff --git a/<path>` headers).
2. Grep the ledger for JSON-quoted `"<path>"` occurrences (fixed-string match, so `src/foo.ts` won't collide with `src/foobar.ts`).
3. Dedup, take the last `CCG_HISTORY_MAX` (default 3) most-recent matches.
4. Render to `<workdir>/history.txt` as a structured Markdown block.

The protocol layer (`ccg.md` step 2.5) splices `history.txt` into both Codex and Gemini prompts before the diff. Each reviewer therefore sees:

```
=== PRIOR REVIEWS (last 3 entries touching these paths) ===
- [2026-05-20T12:00:00Z] sha=ghi9abc mode=quality lines=+8-1
  paths: ["auth/login.go","auth/session.go"]
  synthesis: BLINDSPOT: error logging missing. fix-required.
...
```

Why this matters:
- **Recurring patterns surface.** "Last time we argued about constant-time compare — is this PR repeating that?"
- **Unresolved `fix-required` items don't decay.** If a prior verdict said `fix-required` and the new diff doesn't address it, both reviewers can flag the gap.
- **Two-call cost stays flat.** No extra LLM call; `ccg_ledger_context` is a pure shell function (grep + sed). Marginal cost: tens of milliseconds.

**Cross-shell footgun (worth documenting):** `ccg.sh` is sourced into whatever shell Claude Code's Bash tool runs (bash for default-bash users, **zsh** for default-zsh users). In zsh, `local var` *without* `=` prints the variable's existing value to stdout. If the `local` declarations had stayed inside the rendering loop, iteration 2 onward would have leaked iteration 1's values into `history.txt`. The fix: declare all loop-mutated locals once *outside* the while loop. The regression is locked in by test 15.9.

Knobs:
- `CCG_NO_HISTORY=1` skips the consumer entirely (useful when you want a *single*-perspective baseline review).
- `CCG_HISTORY_MAX=<n>` caps surfaced entries (default 3; larger N inflates prompt size).

**Delete this companion:** ccg goes back to stateless. L6 reverts to a write-only diary — moat by data accumulation, but no compounding leverage within a session.

#### L6 companion — per-review Markdown reports

The ledger optimizes for *aggregation* ("show me everything that touched `src/auth.ts`"), but answers to a different question — *full retrieval* ("what exactly did the models say in that review I ran 3 days ago?") — need a different surface. So `ccg_persist_report <workdir>` writes one self-contained Markdown file per evaluation to `<repo_root>/.ccg/reports/<sha-or-WIP>_<UTC-timestamp>.md`, containing:

- Metadata header (timestamp, branch, SHA, diff source, mode, risk score & reasons, file/line counts)
- Full Claude synthesis (no 400-char truncation — that's a ledger-only concern)
- Raw Codex output (passed through `_ccg_redact`)
- Raw Gemini output (passed through `_ccg_redact`)

This addresses the "evaluation dies in chat" UX gap — once Claude Code session closes, the review text is otherwise gone unless the user manually copies it. Reports persist in the repo where they're discoverable via `find .ccg/reports/`, `gh pr comment --body-file`, IDE search, etc.

Knobs:
- `CCG_NO_REPORT=1` skips persistence entirely.
- `CCG_REPORT_DIR=<path>` relocates the report (useful when running ccg outside a git repo).
- Default location lives **inside the repo** rather than under XDG, because the report is per-repo evaluation context — the user who wants to attach it to a PR or share it with a teammate expects it in the repo tree, not in `~/.local/share/ccg/`.

**Delete this companion:** ccg's L7 output becomes ephemeral again. The ledger query still works for "what touched X?" but answering "what did the model actually say?" requires re-running the review (and re-paying for it).

---

### L7 — Divergence synthesis (Claude-side)
**Problem:** Single-model code review (Copilot, Cursor `/review`, Aider) cannot see its own blind spots. Even with a smart model, you get one perspective.

**Solution:** The L7 logic lives in `ccg.md` (the slash-command protocol Claude follows), not in `ccg.sh`. Claude:

1. Sources `ccg.sh`, calls `ccg_init` to allocate a workdir.
2. Calls `ccg_preflight` to check Codex + Gemini availability.
3. Calls `ccg_diff_capture` (L3) to materialize the diff.
4. Calls `ccg_risk_score` (L5) to choose a mode.
5. Writes one prompt file. Same prompt, different consumers.
6. Calls `ccg_codex` + `ccg_gemini` **in parallel** (both Bash tool calls in the same Claude message).
7. Calls `ccg_actual` (L4) to log real cost.
8. **Synthesizes** the two `[FINDING]`-formatted outputs into AGREEMENT / DIVERGENCE / BLINDSPOT sections — this synthesis happens in Claude's head, not in code.
9. Calls `ccg_ledger_record` (L6) with the synthesis excerpt.
10. Calls `ccg_persist_report` (L6 companion) to materialize the full Markdown report under `<repo>/.ccg/reports/`.
11. Calls `ccg_cleanup` (L1) to remove the workdir.

The protocol explicitly **downgrades** AGREEMENT visibility (one-liner each) and **promotes** DIVERGENCE (full expansion + "NEEDS HUMAN DECISION" tag). This is the product opinion: agreement is low-signal, divergence is the value.

**Delete this layer:** ccg is still useful — you can call individual functions for cost telemetry, risk routing, ledger queries. But the user-facing `/ccg` workflow vanishes.

---

## 4. End-to-end data flow

A single `/ccg` invocation, in chronological order, with which layer owns each step:

```
USER types "/ccg" in Claude Code
       │
       ▼
[Claude reads ccg.md protocol]                               ── protocol
       │
       ▼
ccg_init                                                     ── L1
  └─ mktemp -d -m 700 /tmp/ccg.XXXXXXXX
  └─ emits CCG_DIR=<path>
       │
       ▼
ccg_preflight                                                ── L1
  └─ command -v codex / gemini, $GEMINI_API_KEY check
       │
       ▼
ccg_diff_capture "$CCG_DIR/diff.txt"                         ── L3
  └─ 4-level fallback → emits CCG_DIFF_SOURCE
       │
       ▼
ccg_risk_score "$CCG_DIR/diff.txt"                           ── L5
  └─ rules → emits CCG_RISK_SCORE + CCG_RISK_MODE
  └─ Claude exports CCG_MODE accordingly
       │
       ▼
ccg_ledger_context "$CCG_DIR/diff.txt"                       ── L6 consumer
  └─ greps ledger for prior reviews touching same paths
  └─ writes history.txt for prompt embedding (≤ CCG_HISTORY_MAX entries)
       │
       ▼
[Claude writes codex.prompt + gemini.prompt — same content,  ── protocol
 with history.txt prepended when present]
       │
       ▼
ccg_codex   ─ parallel ─  ccg_gemini                         ── L1 + L2
  │           │             │
  │   L1: timeout + redaction + stdin <&0
  │   L2: cache lookup → either return cached result OR
  │      run CLI then cache the result (on success only)
  │
  └─ both write *.result files
       │
       ▼
ccg_actual <prompt> <result> codex|gemini                    ── L4
  └─ measures tokens, computes USD, appends to usage.log
       │
       ▼
[Claude synthesizes AGREEMENT/DIVERGENCE/BLINDSPOT]          ── L7
  └─ aligns [FINDING] blocks by (file, line, category, title)
  └─ emits "NEEDS HUMAN DECISION" for irreconcilable divergence
       │
       ▼
[Claude writes synthesis.txt — full synthesis content]      ── protocol
       │
       ▼
ccg_ledger_record "$CCG_DIR"                                 ── L6
  └─ JSON-encode + redact synthesis (first 400 chars) + append to ledger.jsonl
       │
       ▼
ccg_persist_report "$CCG_DIR"                                ── L6 companion
  └─ write <repo>/.ccg/reports/<sha>_<ts>.md with full output
       │
       ▼
ccg_cleanup "$CCG_DIR"                                       ── L1
  └─ path-traversal-safe rm -rf
       │
       ▼
USER sees: AGREEMENT / DIVERGENCE / BLINDSPOT + cost line
```

Total typical latency: 5–60 seconds depending on mode. Cost: $0.0007–$0.044, capped by `CCG_MAX_PROMPT_KB`.

---

## 5. Extension points

These are the contracts that contributors and integrators can rely on. Changing the signatures is a breaking change.

### 5.1 Add a new risk-scoring rule (L5)

Edit `ccg.sh:ccg_risk_score`, add a new `if/then` that increments `score` and appends to `reasons`. The output contract is:

```
CCG_RISK_SCORE=<int 0..200>
CCG_RISK_MODE=<cost|balanced|quality>
CCG_RISK_FILES=<int>
CCG_RISK_LINES=+<adds>-<dels>
CCG_RISK_REASONS=<signal+weight signal+weight ...>
```

Anything else parses this output as KEY=VAL lines.

### 5.2 Add a new LLM provider (L1 + L2)

Pattern by example: `ccg_codex` and `ccg_gemini` already implement the contract. To add `ccg_claude`:

1. Resolve a model id from `CCG_MODE` (mirror `_ccg_resolve_codex_model`).
2. Build the cache key including the new provider name.
3. `_ccg_cache_lookup` → if hit, write to result file and return.
4. `_ccg_run_with_timeout <timeout> <cli> -i <prompt> > <result> 2> <err>`.
5. On success, `_ccg_cache_store`.
6. Emit `CCG_CLAUDE_OK=<size>` or `CCG_CLAUDE_FAIL=<reason>`.

The protocol in `ccg.md` would need updating to call the new helper in parallel with the others.

### 5.3 Change storage paths

All paths go through `_ccg_xdg_data_dir` / `_ccg_xdg_cache_dir` / `_ccg_xdg_config_dir`. Override via `XDG_*_HOME` env vars per XDG Base Directory spec, or set explicit `CCG_USAGE_LOG` / `CCG_LEDGER_LOG` / `CCG_CACHE_DIR` for individual files.

Legacy `~/.ccg/` is migrated once on first run by `_ccg_migrate_legacy` — idempotent, non-destructive.

### 5.4 Customize pricing

`_ccg_price <provider> <model> <direction>` returns USD per 1M tokens. Edit this table and the next refresh of `ccg_actual` picks it up immediately.

### 5.5 Customize synthesis output format

The synthesis happens **in Claude's head** following the template in `ccg.md`. To change the format (e.g., add a "SECURITY DIVERGENCE" section), edit the prompt template in `ccg.md` steps 4 + 8. Bash side does not parse the synthesis.

---

## 6. Invariants the test suite verifies

`tests/test_ccg.sh` enforces these — 99 tests at last count. Adding code that violates any of these will break CI.

| Invariant | Why |
|---|---|
| `ccg_init` always returns a workdir under `/tmp` or `$TMPDIR`, never under `$HOME` | crash-safety: a stale workdir won't haunt the user's home |
| Workdir basename starts with `ccg.` | safety guard for `ccg_cleanup`'s allowlist |
| Failed CLI calls never enter the cache or usage log | one-shot 503 must not poison telemetry/cache |
| Secrets in stderr are redacted before any file write | the 7-pattern table |
| `ccg_diff_capture` never returns success with an empty diff | callers can assume non-empty payload |
| Risk score on empty file → `_FAIL=` not 0 | distinguishes "0 risk" from "no signal" |
| Ledger row is always valid JSON, parseable by `json.loads` | grep-able + parse-able |
| `_ccg_run_with_timeout` preserves child exit code precisely | so callers can distinguish 124 (timeout) from 1 (CLI error) |
| Subshells inherit `set -u` from caller without breaking on unset vars | enables strict-mode hosts |

---

## 7. Design decisions worth knowing

These are the choices that look weird at first but have specific reasons. Documenting them so future contributors don't "fix" them.

| Decision | Looks weird because | Real reason |
|---|---|---|
| Bash 3.2+ compatible (no `mapfile`, no `${var,,}`) | Modern bash 5.x has nicer syntax | macOS ships with bash 3.2 due to GPL3 boycott. Bash 5 is an explicit `brew install` away. ccg must work out of the box. |
| Cache key includes model ID, not just prompt hash | "Identical prompt = identical result" seems true | A prompt cached as gpt-5-nano result can't be served as gpt-5 result. Different models, different outputs. |
| AGREEMENT section deliberately one-line per finding | More detail is generally better | If both AI flagged the same issue, your single Claude probably would too. Adding detail to AGREEMENT dilutes the DIVERGENCE signal. This is a product opinion, not a UX accident. |
| Risk-score is pure rules, not LLM | LLM could be smarter | Cost (zero), explainability (regex grep), and "PR-able weights" beat marginal accuracy gains. Also avoids feedback loop where the scorer's own predictions affect what gets reviewed. |
| Failed calls aren't cached even briefly | "Negative cache could prevent retry storms" | A failed call usually means "wrong model name" or "rate limit." Both want to retry once you fix the cause. Caching the failure delays recovery. |
| `~/.ccg/` migration is non-destructive (`mv` not `cp`) | Could leave orphans | Old `~/.ccg/` users explicitly opted in via env vars; copying data leaves duplicates. We move once on first encounter; the dir is removed only if empty. |
| `ccg_cleanup` rejects symlinks, not just `..` | "Path traversal" is the usual scare | `mktemp` already prevents `..`. Symlinks are the actual attack surface (TOCTOU race where symlink swaps mid-cleanup). |
| Slash command protocol lives in `ccg.md`, not in code | Code-as-documentation seems cleaner | Claude reads `ccg.md` as the protocol spec. Bash code can't be Claude's prompt; that's the whole point of slash commands. Splitting protocol (md) from primitives (sh) is the correct boundary. |
| `local var=` (with `=`) is mandatory inside loop bodies | Bash treats `local var` and `local var=` identically | zsh's `local var` (no `=`) *prints* the variable's existing value. ccg.sh is sourced by zsh users via Claude Code's Bash tool — leaking iteration N-1's values into a prompt or output file is a real bug. Test 15.9 guards this. |

---

## 8. Non-goals

What ccg deliberately does **not** try to do, and why.

- **No streaming output.** Claude needs both Codex and Gemini results fully before synthesizing. Streaming would require a different protocol design (and would not improve cost — both reviewers still run to completion).
- **No multi-turn conversation.** Each `/ccg` invocation is fresh; no `continuation_id`. If you want iteration, run `/ccg` again with a refined prompt — caching makes this cheap.
- **No IDE integration beyond Claude Code.** Cursor / Continue / Cline users should look at [zen-mcp-server](https://github.com/BeehiveInnovations/zen-mcp-server). Maintaining ports to N IDEs is not worth the testing burden.
- **No static analysis.** Divergence detection ≠ Semgrep / CodeQL. Use ccg alongside them, not instead.
- **No "review bot."** ccg is human-triggered. Auto-running on every PR creates noise; defeats the "triage tool" positioning.

---

## 9. Where the moat actually lives

Marketing positioning says: **divergence detection** (L7).

The engineering moat is **L6 (ledger + consumer) + L4 (usage)**:

- L7 can be copied in a week. Any team that knows about `gpt-5-mini` + `gemini-2.5-flash` can run the same trick.
- L6 + L4 produce **per-user accumulating data**. After 6 months, a heavy user has a personal historical record that no competitor can replicate — they'd be starting from review #1.
- The `ccg_ledger_context` consumer (added 2026-05) is what makes that data *compound* within a session: each review uses the prior reviews as context. Without it, the ledger was a write-only diary; with it, every review on a touched file builds on the last.

If you're prioritizing what to harden first, harden L6 + L4 first.

---

## 10. File map

```
ccg/
├── ccg.sh                  → all 7 layers below the L7 synthesis (Bash core)
├── ccg.md                  → L7 slash-command protocol (read by Claude, not parsed)
├── bin/ccg.js              → Node CLI wrapper (install / uninstall / doctor / about)
├── scripts/install.sh      → local-clone installer
├── scripts/curl-install.sh → remote one-liner installer
├── tests/test_ccg.sh       → 121 regression + adversarial tests for L1–L6
├── README.md               → English entry point (zh-CN / ja / ko mirror)
├── docs/ARCHITECTURE.md    → this file
└── package.json            → npm publish manifest (@mcgrapeng/ccg)
```

When in doubt: **`bash ccg.sh` is the ground truth, this file is the map**. If they disagree, the code wins and this file is wrong.
