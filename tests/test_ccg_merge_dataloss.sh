#!/usr/bin/env bash
# tests/test_ccg_merge_dataloss.sh — regressions for the merge/conflict
# data-loss bugs found in the V1 production audit:
#   C1 — marker-like lines (e.g. Markdown `=======` setext underline) OUTSIDE a
#        conflict were dropped + committed.
#   C2 — empty/missing resolution wrote contentless markers (dropped both sides);
#        must restore the ORIGINAL block verbatim.
#   H1 — whole-file CRLF→LF conversion on pass-through lines.
#   H2 — `grep -v '^CONFIDENCE:'` deleted interior code lines, not just the
#        trailing AI annotation.
#   H3 — ccg_merge returned exit 0 on a needs-human BLOCKED merge.
set -u

CCG_SH="$(cd "$(dirname "$0")/.." && pwd)/ccg.sh"
PASS=0; FAIL=0
_pass() { printf 'PASS %s\n' "$1"; PASS=$((PASS+1)); }
_fail() { printf 'FAIL %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

export CCG_NO_CACHE=1 CCG_NO_REPORT=1 CCG_NO_HISTORY=1
# shellcheck source=/dev/null
. "$CCG_SH"

# helper: put a resolved file where _ccg_apply_resolutions expects it
_resolved_path() { # <dir> <file> <idx>
  printf '%s/resolved_%s_%s.txt' "$1" "$(_ccg_safe_filename_hash "$2")" "$3"
}

# ── C1: a `=======` line OUTSIDE the conflict must survive apply ──────
t_c1_marker_outside_conflict() {
  local d; d=$(mktemp -d); local f="$d/doc.md" rdir="$d/res"; mkdir -p "$rdir"
  printf 'Heading\n=======\nbefore\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> br\nafter\n=======\n' > "$f"
  printf 'RESOLVED\n' > "$(_resolved_path "$rdir" "$f" 1)"
  _ccg_apply_resolutions "$f" "$rdir" >/dev/null 2>&1
  # Expect: both standalone "=======" underlines survive; conflict→RESOLVED.
  local eqs; eqs=$(grep -c '^=======$' "$f")
  if [ "$eqs" = "2" ] && grep -q '^RESOLVED$' "$f" && grep -q '^Heading$' "$f" && grep -q '^after$' "$f"; then
    _pass "C1 markdown ======= underline survives merge apply"
  else
    _fail "C1 marker-outside-conflict" "eqs=$eqs file:[$(tr '\n' '/' <"$f")]"
  fi
  rm -rf "$d"
}

# ── C2: empty resolution restores the ORIGINAL block verbatim ────────
t_c2_empty_resolution_restores_block() {
  local d; d=$(mktemp -d); local f="$d/code.txt" rdir="$d/res"; mkdir -p "$rdir"
  printf 'top\n<<<<<<< HEAD\nIMPORTANT OURS\n=======\nIMPORTANT THEIRS\n>>>>>>> br\nbottom\n' > "$f"
  # No resolved file created → apply must restore original block, return 1.
  local rc=0
  _ccg_apply_resolutions "$f" "$rdir" >/dev/null 2>&1 || rc=$?
  if grep -q 'IMPORTANT OURS' "$f" && grep -q 'IMPORTANT THEIRS' "$f" \
     && grep -q '^<<<<<<< HEAD' "$f" && grep -q '^>>>>>>> br' "$f" && [ "$rc" = "1" ]; then
    _pass "C2 empty resolution restores original block (no code lost), rc=1"
  else
    _fail "C2 empty-resolution" "rc=$rc file:[$(tr '\n' '/' <"$f")]"
  fi
  rm -rf "$d"
}

# ── H1: CRLF on pass-through lines is preserved ──────────────────────
t_h1_crlf_preserved() {
  local d; d=$(mktemp -d); local f="$d/win.txt" rdir="$d/res"; mkdir -p "$rdir"
  printf 'alpha\r\nbeta\r\n<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> br\r\ngamma\r\n' > "$f"
  printf 'RES\n' > "$(_resolved_path "$rdir" "$f" 1)"
  _ccg_apply_resolutions "$f" "$rdir" >/dev/null 2>&1
  local cr; cr=$(tr -cd '\r' < "$f" | wc -c | tr -d ' ')
  # alpha, beta, gamma each keep their CR (>=3); old code stripped ALL CRs → 0.
  if [ "$cr" -ge 3 ]; then
    _pass "H1 CRLF preserved on pass-through lines (cr=$cr)"
  else
    _fail "H1 crlf-preserved" "cr=$cr (expected >=3)"
  fi
  rm -rf "$d"
}

# ── H2: only a TRAILING CONFIDENCE line is stripped, not interior code ─
t_h2_confidence_interior_kept() {
  local d; d=$(mktemp -d); local f="$d/c.yml" rdir="$d/res"; mkdir -p "$rdir"
  printf 'x\n<<<<<<< HEAD\na\n=======\nb\n>>>>>>> br\ny\n' > "$f"
  printf 'line1\nCONFIDENCE: this is a real config key\nline3\nCONFIDENCE: high\n' > "$(_resolved_path "$rdir" "$f" 1)"
  _ccg_apply_resolutions "$f" "$rdir" >/dev/null 2>&1
  if grep -q '^CONFIDENCE: this is a real config key$' "$f" \
     && ! grep -q '^CONFIDENCE: high$' "$f" \
     && grep -q '^line1$' "$f" && grep -q '^line3$' "$f"; then
    _pass "H2 interior CONFIDENCE: kept, trailing annotation stripped"
  else
    _fail "H2 confidence-interior" "file:[$(tr '\n' '/' <"$f")]"
  fi
  rm -rf "$d"
}

# ── H3: ccg_merge on a needs-human conflict returns exit 1 ───────────
t_h3_needs_human_exit1() {
  local repo; repo=$(mktemp -d); repo=$(cd "$repo" && pwd -P)
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  printf 'line1\nline2\nline3\n' > "$repo/f.txt"
  git -C "$repo" add -A; git -C "$repo" commit -q -m init
  git -C "$repo" checkout -q -b feature
  printf 'line1\nFEATURE\nline3\n' > "$repo/f.txt"; git -C "$repo" commit -q -am feat
  git -C "$repo" checkout -q main
  printf 'line1\nMAIN\nline3\n' > "$repo/f.txt"; git -C "$repo" commit -q -am main2
  git -C "$repo" checkout -q feature
  local rc=0
  (
    cd "$repo"
    # No API keys, no codex/gemini → resolver escalates to NEEDS_HUMAN.
    unset BAILIAN_API_KEY GEMINI_API_KEY ANTHROPIC_API_KEY CLAUDE_API_KEY
    export CCG_MERGE_NO_FETCH=1 PATH="/usr/bin:/bin:/usr/sbin:/sbin"
    . "$CCG_SH"
    ccg_merge main >/dev/null 2>&1
  ) || rc=$?
  if [ "$rc" = "1" ]; then
    _pass "H3 ccg_merge returns exit 1 on needs-human blocked merge"
  else
    _fail "H3 needs-human-exit1" "expected rc=1 got rc=$rc"
  fi
  rm -rf "$repo"
}

t_c1_marker_outside_conflict
t_c2_empty_resolution_restores_block
t_h1_crlf_preserved
t_h2_confidence_interior_kept
t_h3_needs_human_exit1

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
