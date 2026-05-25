# ccg — Code Divergence Detector

> Surface where Codex and Gemini disagree on your code — that's where you need to make a call.
> 
> A Claude Code slash command. Install once, type `/ccg` on a diff.

[![Tests](https://img.shields.io/badge/tests-111%20passing-brightgreen.svg)]()
[![npm](https://img.shields.io/npm/v/@mcgrapeng/ccg.svg)](https://www.npmjs.com/package/@mcgrapeng/ccg)
[![npm downloads](https://img.shields.io/npm/dm/@mcgrapeng/ccg.svg)](https://www.npmjs.com/package/@mcgrapeng/ccg)
[![GitHub stars](https://img.shields.io/github/stars/mcgrapeng/ccg.svg?style=social&label=Star)](https://github.com/mcgrapeng/ccg/stargazers)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**English** ｜ [简体中文](README.zh-CN.md) ｜ [日本語](README.ja.md) ｜ [한국어](README.ko.md)　·　[Architecture →](docs/ARCHITECTURE.md)

---

## What is ccg

You're about to merge a change to `auth/login.go`. You want a sanity check. Today you have three options, all of them flawed:

- **Single-model review** (Copilot, Cursor `/review`, Aider) gives you **one perspective**. If Claude misses a timing attack, you miss it too.
- **Multi-model gateways** (zen-mcp-server etc.) **average opinions**, hiding exactly the places where smart models disagreed — which is the only place you actually needed help.
- **Manual cross-checking** is what you'd do if you had unlimited time. You don't.

ccg is a `/ccg` slash command for Claude Code that fixes all three. On any diff, it:

1. Sends the same prompt to **Codex (OpenAI)** and **Gemini (Google)** in parallel
2. Has **Claude** read both reports and surface **specifically where they disagree** — that's where human judgment is needed
3. Tracks cost, picks the cheapest model good enough for the risk level, and remembers past reviews

**Think of it like:** asking two senior engineers from different teams to review the same PR, then having a tech lead synthesize: "they agree on these issues, they disagree on this one — you decide, and here's my read."

## What ccg does (5 core capabilities)

1. **Parallel reviews** — same prompt to Codex + Gemini simultaneously
2. **Divergence detection** — Claude surfaces where they disagree (not where they agree)
3. **Risk-aware routing** — auto-scores your diff, picks cost / balanced / quality mode
4. **Cost tracking** — logs every call; 24h cache makes repeat reviews free ($0.00)
5. **Review memory** — saves past reviews; next review auto-injects history so recurring patterns surface instead of decaying between sessions

## When to use ccg

The trigger isn't a *domain* — it's a *feeling*. Use ccg when, looking at your own diff, you catch yourself thinking:

| Inner monologue | Use ccg? |
|---|---|
| "If I get this wrong, I'll get paged at 3am." | ✅ Yes |
| "This is a judgment call — no obviously right answer." | ✅ Yes |
| "I wish someone else would look at this first." | ✅ Yes |
| "I just renamed a variable." | ❌ No |
| "Docs-only change." | ❌ No |
| "I want streaming chat with one model." | ❌ No (use the CLI directly) |

**Examples across domains** — none of these are auth/crypto, all of them are real "two senior engineers would disagree" moments:

- **Social platforms** — re-ranking the feed with a new engagement signal · comment-thread fan-out strategy · A/B test bucketing logic · anti-abuse rate-limit policy · graph-DB schema for follow relationships
- **Data / AI infra** — switching embedding model (do you re-index?) · changing chunking strategy · RAG retrieval scoring · prompt-injection defense layering
- **Frontend** — SSR vs ISR vs RSC for a new page · cache invalidation strategy · state-management refactor · accessibility trade-offs
- **API design** — cursor vs offset pagination · error response model · versioning approach · idempotency-key handling
- **Distributed systems** — timeout/retry policy · cache TTL vs event-driven invalidation · partition tolerance trade-off · leader-election semantics
- **Database** — multi-step migration sequencing · index choice on a hot path · transaction isolation level · soft-delete vs hard-delete
- **Security** — yes, auth / crypto / payments too — but just one of many domains

**The pattern:** any change where a reasonable engineer might pick option A and another reasonable engineer might pick option B. That's when divergence detection earns its $0.04.

## Why ccg (vs everything else)

**1. Disagreement is the signal, not the noise.**
When Codex says "use `subtle.ConstantTimeCompare`" and Gemini says "bcrypt is already constant-time, that's cargo-cult", *that* is where you need to think. Other tools blend these into a vague "consider timing attacks". ccg shows you the conflict verbatim.

**2. Cost telemetry built in.**
Codex/Gemini CLIs don't tell you what you spent. ccg logs every call, picks the cheapest sufficient model automatically (risk-aware routing), and caches identical prompts for 24h at zero cost. Typical spend: $0.02–0.15 per meaningful divergence review — a single senior code review costs $200–300 in time. Divergence detection earns its cost on the first contentious PR. Check accumulated spend anytime with `ccg_usage --this-month`.

**3. A review history that survives across sessions — *and feeds the next review*.**
"What did the model say about `src/auth.ts` two weeks ago?" — ccg's append-only ledger answers that. No stateless tool can. As of v3.2, prior reviews touching the same files are auto-injected into the next prompt. Recurring patterns surface instead of decaying. Unresolved `fix-required` items don't get lost between sessions.

## Install

One-liner (no Node required):

```bash
curl -fsSL https://raw.githubusercontent.com/mcgrapeng/ccg/main/scripts/curl-install.sh | bash
```

Then install the AI CLIs (one-time):

```bash
npm i -g @openai/codex @google/gemini-cli
echo 'export GEMINI_API_KEY="<your-key>"' >> ~/.zshenv
```

Verify:

```bash
npx @mcgrapeng/ccg doctor      # check Codex / Gemini / API key
npx @mcgrapeng/ccg about       # 7-layer capability probe + runtime state
```

## Example divergences (the patterns ccg catches)

Disagreement happens everywhere, not just security. Here's what divergence looks like in different domains:

**Crypto/Security (classic)**
```
▸ auth/login.go:6 — bcrypt hash comparison
  🔵 Codex: "Wrap with subtle.ConstantTimeCompare to prevent timing attacks"
  🟢 Gemini: "bcrypt is already constant-time. Wrapping is cargo-cult"
  ⚖️ Decision: You pick based on threat model
```

**Frontend (cache strategy)**
```
▸ cache.ts:42 — invalidate on write or subscribe to events?
  🔵 Codex: "Always revalidate on write (predictable, simpler)"
  🟢 Gemini: "Event subscription scales better; write-revalidate causes cache storms"
  ⚖️ Decision: You pick based on traffic patterns and SLA
```

**API Design (pagination)**
```
▸ pagination.go:18 — cursor vs offset pagination?
  🔵 Codex: "Offset is simpler, users expect it"
  🟢 Gemini: "Cursor is O(1), offset is O(n) on deletion; pick by growth rate"
  ⚖️ Decision: You pick based on data churn and growth projections
```

That disagreement is where ccg earns its cost. See a full-depth example below.

## Try it — a complete walkthrough

Say you just edited `auth/login.go`:

```go
// before                                            // after
func Login(user, pw string) bool {                   func Login(user, pw string) bool {
    u := lookupUser(user)                                u := lookupUser(user)
-   return u.Hash == sha256.Sum256([]byte(pw))           hashed, err := bcrypt.GenerateFromPassword([]byte(pw), 12)
+                                                        if err != nil { return false }
+                                                        return subtle.ConstantTimeCompare(u.Hash, hashed) == 1
}
```

You open Claude Code and type:

```
/ccg
```

After ~30 seconds you see something like this — **real output**, not a placeholder:

```
📍 Scope: worktree · 1 file · +4 -1 lines
🎯 Mode:  quality  (risk=65 · auth+35 size>0+5 crypto-mention+25)
🩺 Both reviewers OK: Codex ✓ · Gemini ✓
💰 Cost: $0.041

═══ AGREEMENT (2) — both flagged, low signal ═══
• auth/login.go:3 — sha256 wasn't a password hash; bcrypt is correct
• auth/login.go:5 — handle the bcrypt error explicitly (you do)

═══ DIVERGENCE (1) — the models disagreed ★ you decide ═══

▸ auth/login.go:6 — how to compare bcrypt hashes
  🔵 Codex:   "Wrap with subtle.ConstantTimeCompare to prevent timing attacks
              even with bcrypt."
  🟢 Gemini:  "bcrypt.CompareHashAndPassword is already constant-time. Wrapping
              it is cargo-cult and can mask bugs (length mismatch panics)."
  ⚖️ Claude:  Gemini is correct. bcrypt.CompareHashAndPassword is the canonical
              comparison; ConstantTimeCompare on its raw output is a category
              error — you'd be comparing the freshly-hashed `pw` against the
              stored hash, but bcrypt salts each hash uniquely so direct
              comparison ALWAYS returns false.
  ➡️ Action:  Replace the ConstantTimeCompare line with:
              `err := bcrypt.CompareHashAndPassword(u.Hash, []byte(pw))`
              `return err == nil`

═══ BLINDSPOT (1) — neither saw, Claude suspects ═══
• Error path: returning `false` on bcrypt error is correct for the caller but
  silently swallows infrastructure errors (e.g. bcrypt OOM). Log the error.

═══ VERDICT: fix-required ═══
The comparison logic as written will always reject valid passwords. Apply
the DIVERGENCE action, add error logging, and you're good to merge.
```

### How to read this output

| Section | What it means | What to do |
|---|---|---|
| **AGREEMENT** | Both Codex and Gemini flagged the same thing. Your single-source Claude likely catches these too — **low new information**. | Skim, fix if not already done. |
| **DIVERGENCE** ★ | The two models disagreed. **This is the whole reason ccg exists.** Claude's "Action" line gives you a recommendation, but you're the final decider. | Read carefully. Apply Claude's call or override it. |
| **BLINDSPOT** | Neither model raised it, but Claude noticed something while synthesizing. **Use sparingly** — limit 2 per run. | Treat as a hint, not gospel. |
| **VERDICT** | `merge` / `fix-required` / `discuss`. One-line summary. | **Use as your merge gate.** |

After the review, `ccg_ledger_record` writes one JSONL line to your ledger. Two weeks from now you can:

```bash
source ~/.claude/commands/ccg.sh
ccg_ledger_query "auth/login.go"
# → "auth/login.go: 3 reviews · last 2026-05-23 (fix-required) · 2026-05-09 (merge) · 2026-04-28 (discuss)"
```

The same review is also persisted as a self-contained markdown report at `.ccg/reports/<sha>_<utc-timestamp>.md` inside your repo. Useful when you close Claude Code and still want the full output — synthesis + raw Codex + raw Gemini — to be readable later without re-running. Set `CCG_NO_REPORT=1` to opt out, or `CCG_REPORT_DIR=<path>` to relocate. (Tip: add `.ccg/` to your `.gitignore` unless you want the reports tracked.)

## Configure (defaults are usually fine)

Mode and model picks are automatic. Override only when needed:

```bash
CCG_MODE=quality /ccg          # force quality models on any diff
CCG_CODEX_MODEL=o3 /ccg        # override one model
CCG_NO_CACHE=1 /ccg            # skip 24h cache for this call
```

Common knobs (full list in [Architecture → §5](docs/ARCHITECTURE.md#5-extension-points)):

| Variable | Default | Purpose |
|---|---|---|
| `CCG_MODE` | `auto` | `auto` / `cost` / `balanced` / `quality` |
| `CCG_CACHE_TTL_HOURS` | `24` | Cache TTL |
| `CCG_MAX_PROMPT_KB` | `100` | Per-call prompt size cap |
| `CCG_NO_HISTORY` | `0` | Set to `1` to disable review history injection |
| `CCG_HISTORY_MAX` | `3` | Max number of prior reviews to inject |

Cost reference (USD per call, after cache hit):

| Mode | Codex | Gemini | Typical cost |
|---|---|---|---|
| `cost`     | gpt-5-nano  | gemini-2.5-flash-lite | ~$0.0007 |
| `balanced` | gpt-5-mini  | gemini-2.5-flash      | ~$0.0046 |
| `quality`  | gpt-5       | gemini-2.5-pro        | ~$0.0440 |

Track your spend:

```bash
source ~/.claude/commands/ccg.sh
ccg_usage --this-month      # monthly breakdown by provider
ccg_usage --all             # cumulative
```

## Not for (scope boundaries)

ccg is purpose-built for high-judgment code reviews. It's *not* a replacement for:

- **Static analysis** — pair it with Semgrep / CodeQL, don't use it instead
- **Linters or formatters** — those catch style; ccg catches architecture
- **Streaming dialogue** — ccg is one-shot; for multi-turn conversation use the Codex / Gemini CLIs directly
- **IDEs other than Claude Code** — try [zen-mcp-server](https://github.com/BeehiveInnovations/zen-mcp-server) for VS Code / JetBrains

## SVN support (experimental)

ccg works with SVN 1.7+ working copies, including TortoiseSVN 1.10.

```bash
# In your SVN working copy:
source /path/to/ccg.sh
ccg_install_hook   # writes .ccg-precommit-hook.sh + prints TortoiseSVN config string
```

`svn diff --git` produces standard unified diff format, so all ccg layers (risk scoring, ledger, history) work without modification. SVN revision numbers are stored as `r<N>` in place of git SHAs.

See [docs/SVN.md](docs/SVN.md) for TortoiseSVN setup, Windows `.bat` wrapper, and offline fallback.

## Commit gate (pre-commit hook)

Block commits when ccg verdict is `fix-required`:

```bash
source /path/to/ccg.sh
ccg_install_hook   # git: writes .git/hooks/pre-commit  |  svn: writes .ccg-precommit-hook.sh
```

| Verdict | Default | Override |
|---|---|---|
| `merge` | allow | — |
| `fix-required` | **block** | — |
| `discuss` | allow | `CCG_GATE_DISCUSS=block` |

Set `CCG_GATE_OFFLINE=1` to skip the LLM review when offline.

## Architecture & contributing

ccg is **8 layers** (L0–L7), only the top one is "divergence detection". Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing anything in `ccg.sh`.

Tests:

```bash
bash tests/test_ccg.sh                # 99 regression tests, ~31s
REAL_CLI=1 bash tests/test_ccg.sh     # +2 live API tests (incurs cost)
```

## License & credits

MIT — see [LICENSE](LICENSE).

Built on [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode)'s original `/ccg` concept · Claude Code · OpenAI Codex CLI · Google Gemini CLI.
