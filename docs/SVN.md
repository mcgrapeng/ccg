# ccg SVN Integration

ccg supports SVN working copies (SVN 1.7+, tested with TortoiseSVN 1.10).

## How it works

`svn diff --git` produces standard unified diff with `diff --git a/...` headers,
so all ccg parsers (risk scoring, ledger, history) work without modification.
SVN revision numbers are stored as `r<N>` in place of git SHAs.

## Prerequisites

- SVN 1.7+ CLI (`svn` on PATH)
- Codex CLI: `npm i -g @openai/codex`
- Gemini CLI: `npm i -g @google/gemini-cli` + `GEMINI_API_KEY` set
- **Windows only**: [Git for Windows](https://gitforwindows.org/) (provides `bash`)

## Quick start (any platform)

```bash
# In your SVN working copy:
source /path/to/ccg.sh
ccg_install_hook
```

This writes `.ccg-precommit-hook.sh` to your working copy root and prints
the exact string to paste into TortoiseSVN.

## TortoiseSVN 1.10 setup

1. Open TortoiseSVN → **Settings** → **Hook Scripts** → **Add**
2. Fill in:

   | Field | Value |
   |---|---|
   | Hook type | `Pre-Commit Hook` |
   | Working copy path | `C:\path\to\your\wc` |
   | Command line | `bash "C:\path\to\your\wc\.ccg-precommit-hook.sh"` |
   | Wait for script to finish | ✅ checked |
   | Hide script while running | unchecked (so you see the verdict) |

3. Click **OK** → **Apply**.

Alternatively, use the `.bat` wrapper (no bash shebang needed in the command line):

```
"C:\path\to\ccg\bin\ccg-precommit.bat" %WC% %MESSAGEFILE% %CWD%
```

Edit `ccg-precommit.bat` to set `CCG_SH` to the absolute path of `ccg.sh`.

## Verdict behaviour

| Verdict | Default | Override |
|---|---|---|
| `merge` | commit allowed | — |
| `fix-required` | commit **blocked** | — |
| `discuss` | commit allowed | `CCG_GATE_DISCUSS=block` to block |

## Offline / no-network fallback

Set `CCG_GATE_OFFLINE=1` to skip the LLM review and always allow the commit.
Useful when the machine has no internet access.

```bat
:: In ccg-precommit.bat, add before the bash call:
set CCG_GATE_OFFLINE=1
```

## Uninstall

```bash
source /path/to/ccg.sh
ccg_uninstall_hook   # removes .ccg-precommit-hook.sh
```

Then remove the entry from TortoiseSVN Settings → Hook Scripts.

## Diff scope

ccg tries four levels in order, stopping at the first non-empty result:

1. Uncommitted working-copy changes (`svn diff --git`)
2. BASE vs HEAD (`svn diff --git -rBASE:HEAD`)
3. Previous revision vs current (`svn diff --git -r<N-1>:<N>`)

If all levels return empty, the gate is skipped with `CCG_DIFF_FAIL=empty-diff`.
