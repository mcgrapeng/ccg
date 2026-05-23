# ccg — Code Divergence Detector

> A Claude Code slash command. Install once, type `/ccg` on a diff.

[![Tests](https://img.shields.io/badge/tests-99%20passing-brightgreen.svg)]()
[![npm](https://img.shields.io/npm/v/@mcgrapeng/ccg.svg)](https://www.npmjs.com/package/@mcgrapeng/ccg)
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

## When to use ccg

| Scenario | Use ccg? | Why |
|---|---|---|
| Touching auth / payments / migrations / crypto | ✅ Yes | Different training data catches different bugs. Worth $0.04. |
| Solo dev or 2-person team, no second reviewer | ✅ Yes | Closest thing to "another pair of eyes" |
| Pre-merge sanity check on a 200-line PR | ✅ Yes | Risk-router picks the right model automatically |
| Renaming a variable | ❌ No | Just commit |
| Docs-only edit | ❌ No | Risk router auto-downgrades to ~$0.0007 but truly not needed |
| Want streaming chat with one model | ❌ No | Use codex/gemini CLI directly |

## Why ccg (vs everything else)

**1. Disagreement is the signal, not the noise.**
When Codex says "use `subtle.ConstantTimeCompare`" and Gemini says "bcrypt is already constant-time, that's cargo-cult", *that* is where you need to think. Other tools blend these into a vague "consider timing attacks". ccg shows you the conflict verbatim.

**2. Cost telemetry built in.**
Codex/Gemini CLIs don't tell you what you spent. ccg logs every call, picks the cheapest sufficient model automatically (risk-aware routing), and caches identical prompts for 24h. `ccg_usage --this-month` answers "how much have I spent so far?".

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

Verify:

```bash
npx @mcgrapeng/ccg doctor      # check Codex / Gemini / API key
npx @mcgrapeng/ccg about       # 7-layer capability probe + runtime state
```

## Try it — a walkthrough

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
| **VERDICT** | `merge` / `fix-required` / `discuss`. One-line summary. | Use as merge gate. |

After the review, `ccg_ledger_record` writes one JSONL line to your ledger. Two weeks from now you can:

```bash
source ~/.claude/commands/ccg.sh
ccg_ledger_query "auth/login.go"
# → "auth/login.go: 3 reviews · last 2026-05-23 (fix-required) · 2026-05-09 (merge) · 2026-04-28 (discuss)"
```

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
