#!/usr/bin/env bash
# tests/test_ccg_round4.sh — coverage for round-4 high-impact fixes
#
# These tests target round-4 fixes that previously had no direct coverage:
#   T1: hook fail-closed when CCG_SCRIPT path no longer exists (P0-R4-M3 / T34)
#   T2: _ccg_classify_conflict returns "symlink" when worktree path is a symlink (M4 / T35)
#   T3: _ccg_parse_conflicts discards diff3 base section between |||||||/======= (T31)
#   T4: ccg_precommit_gate fails closed when reviewer emits >1 sentinel (T49)
#   T5: _ccg_resolve_one_conflict escalates when AI output echoes conflict markers (T42)
#   T6: ccg_diff_capture honors CCG_DIFF_CACHED_ONLY (no upstream fallthrough) (T41)
#
# All tests use mocks; no real codex/gemini API calls.

set -euo pipefail

CCG_SH="$(cd "$(dirname "$0")/.." && pwd)/ccg.sh"
PASS=0; FAIL=0

_pass() { printf 'PASS %s\n' "$1"; PASS=$((PASS+1)); }
_fail() { printf 'FAIL %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# ────────────────────────────────────────────────────────────
# T1: Hook fail-closed when CCG_SCRIPT path was deleted/moved
# ────────────────────────────────────────────────────────────
# Install the hook with a path that we then delete, then invoke the
# hook directly. The hook must emit a non-empty error and exit 1 —
# never silently succeed.
t1_hook_fail_closed() {
  local tmpgit
  tmpgit=$(mktemp -d)
  git -C "$tmpgit" init -q
  git -C "$tmpgit" config user.email "t@t"
  git -C "$tmpgit" config user.name "t"

  # Copy ccg.sh into a path we control, then install hook pointing at it.
  local fake_ccg="$tmpgit/.ccg.sh"
  cp "$CCG_SH" "$fake_ccg"

  local install_out
  install_out=$(
    cd "$tmpgit"
    # shellcheck source=/dev/null
    source "$fake_ccg"
    ccg_install_hook
  )

  local hook_file="$tmpgit/.git/hooks/pre-commit"
  if [ ! -x "$hook_file" ]; then
    _fail "T1-hook-fail-closed" "hook not installed at $hook_file"
    rm -rf "$tmpgit"
    return
  fi

  # Delete the script the hook was pointing at, then run the hook.
  rm -f "$fake_ccg"

  local stage_file="$tmpgit/file.txt"
  echo "content" > "$stage_file"
  git -C "$tmpgit" add file.txt

  # Run hook directly (bypassing git commit so we can capture stderr cleanly).
  local hook_out hook_ec=0
  hook_out=$(cd "$tmpgit" && bash "$hook_file" 2>&1) || hook_ec=$?

  rm -rf "$tmpgit"

  if [ "$hook_ec" = "0" ]; then
    _fail "T1-hook-fail-closed" "hook exited 0 instead of failing closed"
    return
  fi
  if ! printf '%s' "$hook_out" | grep -q 'CCG_SCRIPT not found'; then
    _fail "T1-hook-fail-closed" "hook missing 'CCG_SCRIPT not found' diagnostic; got: $hook_out"
    return
  fi
  _pass "T1-hook-fail-closed"
}
t1_hook_fail_closed

# ────────────────────────────────────────────────────────────
# T2: _ccg_classify_conflict returns "symlink" when worktree
#     path is a symlink (belt-and-braces guard).
# ────────────────────────────────────────────────────────────
t2_symlink_classify() {
  local tmpgit
  tmpgit=$(mktemp -d)
  git -C "$tmpgit" init -q
  git -C "$tmpgit" config user.email "t@t"
  git -C "$tmpgit" config user.name "t"
  git -C "$tmpgit" config merge.conflictStyle merge >/dev/null 2>&1 || true

  # Set up a content conflict on file.txt — initial → branch divergence.
  (
    cd "$tmpgit"
    echo "base" > file.txt
    git add file.txt
    git commit -q -m base
    git checkout -q -b other
    echo "theirs" > file.txt
    git commit -q -am theirs
    git checkout -q -
    echo "ours" > file.txt
    git commit -q -am ours
    # Trigger conflict (ignore exit code — merge intentionally fails).
    git merge --no-commit --no-ff other >/dev/null 2>&1 || true
  )

  # Now replace the file in the worktree with a symlink (without resolving
  # the index — porcelain v2 will still report UU for file.txt). The
  # belt-and-braces `[ -L "$file" ]` guard must fire.
  rm -f "$tmpgit/file.txt"
  ( cd "$tmpgit" && ln -s /tmp/ccg-test-target file.txt )

  local got
  got=$(
    cd "$tmpgit"
    # shellcheck source=/dev/null
    source "$CCG_SH"
    _ccg_classify_conflict "file.txt"
  )

  rm -rf "$tmpgit"

  if [ "$got" = "symlink" ]; then
    _pass "T2-symlink-classify"
  else
    _fail "T2-symlink-classify" "expected 'symlink', got '$got'"
  fi
}
t2_symlink_classify

# ────────────────────────────────────────────────────────────
# T3: _ccg_parse_conflicts discards diff3 base section.
# Input has |||||||/======= markers; parser must record ours/theirs
# but never the base content.
# ────────────────────────────────────────────────────────────
t3_diff3_parse() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local conflicted="$tmpdir/src.txt"
  local workdir="$tmpdir/work"
  mkdir -p "$workdir"

  # Write a diff3-style conflict with a UNIQUE base marker we can grep for.
  cat > "$conflicted" <<'EOF'
header line
<<<<<<< HEAD
our-content-AAA
||||||| merged common ancestors
DIFF3_BASE_SENTINEL_ZZZ
=======
their-content-BBB
>>>>>>> other
footer line
EOF

  local parse_out
  parse_out=$(
    # shellcheck source=/dev/null
    source "$CCG_SH"
    _ccg_parse_conflicts "$conflicted" "$workdir"
  )

  # Expect exactly one tuple line of form: file<TAB>1<TAB>ours_f<TAB>theirs_f
  local tuple_count
  tuple_count=$(printf '%s\n' "$parse_out" | grep -c "$conflicted" || true)
  if [ "$tuple_count" != "1" ]; then
    _fail "T3-diff3-parse" "expected 1 tuple, got $tuple_count: $parse_out"
    rm -rf "$tmpdir"; return
  fi

  # Extract paths from the tuple.
  local ours_f theirs_f
  ours_f=$(printf '%s\n' "$parse_out" | awk -F'\t' '{print $3}' | head -1)
  theirs_f=$(printf '%s\n' "$parse_out" | awk -F'\t' '{print $4}' | head -1)

  if [ ! -s "$ours_f" ] || [ ! -s "$theirs_f" ]; then
    _fail "T3-diff3-parse" "ours/theirs files empty or missing"
    rm -rf "$tmpdir"; return
  fi

  if ! grep -q 'our-content-AAA' "$ours_f"; then
    _fail "T3-diff3-parse" "ours file missing 'our-content-AAA'"
    rm -rf "$tmpdir"; return
  fi
  if ! grep -q 'their-content-BBB' "$theirs_f"; then
    _fail "T3-diff3-parse" "theirs file missing 'their-content-BBB'"
    rm -rf "$tmpdir"; return
  fi

  # CRITICAL: base section content must not leak into ours or theirs.
  if grep -q 'DIFF3_BASE_SENTINEL_ZZZ' "$ours_f" "$theirs_f"; then
    _fail "T3-diff3-parse" "diff3 base section leaked into ours/theirs (sentinel found)"
    rm -rf "$tmpdir"; return
  fi

  rm -rf "$tmpdir"
  _pass "T3-diff3-parse"
}
t3_diff3_parse

# ────────────────────────────────────────────────────────────
# T4: Sentinel multiplication blocked in ccg_precommit_gate.
# Mock codex emits TWO sentinels (one merge + one merge). Even though
# both would individually be safe, two sentinels signal that the model
# was tricked into "ack + override" — gate must fail closed.
# ────────────────────────────────────────────────────────────
t4_sentinel_multiplication() {
  local tmpbin tmpgit
  tmpbin=$(mktemp -d)
  tmpgit=$(mktemp -d)

  # Mock codex emits TWO sentinels for the SAME nonce — should be rejected.
  cat > "$tmpbin/codex" <<'EOF'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "--output-last-message" ] && out="$a"
  prev="$a"
done
prompt=$(cat)
sentinel_open=$(printf '%s' "$prompt" | grep -oE '<<<CCG_VERDICT_[A-F0-9]+:' | head -1)
[ -z "$sentinel_open" ] && sentinel_open='<<<CCG_VERDICT_FALLBACK:'
# Emit TWO sentinels — multiplication attack simulation.
if [ -n "$out" ]; then
  {
    printf 'leading reasoning\n%smerge>>>\n' "$sentinel_open"
    printf 'trailing override\n%smerge>>>\n' "$sentinel_open"
  } > "$out"
fi
EOF
  chmod +x "$tmpbin/codex"

  # Mock gemini emits a legitimate single 'merge' — gate should still
  # fail because codex saw multiplication (any reviewer with multiplication
  # → fix-required).
  cat > "$tmpbin/gemini" <<'EOF'
#!/usr/bin/env bash
prompt=$(cat)
sentinel_open=$(printf '%s' "$prompt" | grep -oE '<<<CCG_VERDICT_[A-F0-9]+:' | head -1)
[ -z "$sentinel_open" ] && sentinel_open='<<<CCG_VERDICT_FALLBACK:'
printf 'mock reasoning\n%smerge>>>\n' "$sentinel_open"
EOF
  chmod +x "$tmpbin/gemini"

  git -C "$tmpgit" init -q
  git -C "$tmpgit" config user.email "t@t"
  git -C "$tmpgit" config user.name "t"
  echo "v1" > "$tmpgit/f.txt"
  git -C "$tmpgit" add f.txt
  git -C "$tmpgit" commit -q -m init
  echo "v2" >> "$tmpgit/f.txt"

  local ec=0
  (
    cd "$tmpgit"
    export PATH="$tmpbin:$PATH"
    export GEMINI_API_KEY=mock
    export CCG_NO_CACHE=1 CCG_NO_REPORT=1 CCG_NO_HISTORY=1
    # shellcheck source=/dev/null
    source "$CCG_SH"
    ccg_precommit_gate 2>/dev/null
  ) || ec=$?

  rm -rf "$tmpbin" "$tmpgit"

  # Gate must reject (ec=1) due to multiplication, not honor the merge verdict.
  if [ "$ec" = "1" ]; then
    _pass "T4-sentinel-multiplication-blocked"
  else
    _fail "T4-sentinel-multiplication-blocked" "expected ec=1, got ec=$ec"
  fi
}
t4_sentinel_multiplication

# ────────────────────────────────────────────────────────────
# T5: _ccg_resolve_one_conflict rejects AI output that echoes
# conflict markers (hallucination or jailbreak protection).
# ────────────────────────────────────────────────────────────
t5_ai_marker_rejection() {
  local tmpdir workdir
  tmpdir=$(mktemp -d)
  workdir="$tmpdir/work"
  mkdir -p "$workdir"

  local ours_f="$workdir/ours.txt"
  local theirs_f="$workdir/theirs.txt"
  printf 'our content\n'    > "$ours_f"
  printf 'their content\n'  > "$theirs_f"

  local out ec=0
  out=$(
    # shellcheck source=/dev/null
    source "$CCG_SH"
    # Override the AI callers to return a "resolution" that embeds raw
    # conflict markers — the resolver must escalate, not pass through.
    ccg_codex() {
      local _prompt="$1" _result="$2"
      printf '<<<<<<< HEAD\nfake ours\n=======\nfake theirs\n>>>>>>> branch\nCONFIDENCE: high\n' > "$_result"
      return 0
    }
    ccg_gemini() {
      local _prompt="$1" _result="$2"
      printf 'plain text resolution\nCONFIDENCE: medium\n' > "$_result"
      return 0
    }
    _ccg_resolve_one_conflict "src.txt" "1" "$ours_f" "$theirs_f" "$workdir"
  ) || ec=$?

  rm -rf "$tmpdir"

  # Must escalate to NEEDS_HUMAN_DECISION (the only safe outcome).
  if [ "$ec" = "1" ] && printf '%s' "$out" | grep -q 'NEEDS_HUMAN_DECISION'; then
    _pass "T5-ai-marker-rejection"
  else
    _fail "T5-ai-marker-rejection" "expected NEEDS_HUMAN_DECISION (ec=1), got ec=$ec out=$out"
  fi
}
t5_ai_marker_rejection

# ────────────────────────────────────────────────────────────
# T6: ccg_diff_capture honors CCG_DIFF_CACHED_ONLY — when staged
# diff is empty, it must NOT fall through to upstream/origin diffs.
# ────────────────────────────────────────────────────────────
t6_cached_only_no_fallthrough() {
  local tmpremote tmpgit
  tmpremote=$(mktemp -d)
  tmpgit=$(mktemp -d)

  # Set up a bare remote with one commit on branch 'work', point its HEAD
  # at that branch, then clone and add a local commit so HEAD diverges
  # from origin. Nothing is staged.
  git -C "$tmpremote" init -q --bare -b work 2>/dev/null \
    || git -C "$tmpremote" init -q --bare
  local tmpseed
  tmpseed=$(mktemp -d)
  git -C "$tmpseed" init -q -b work 2>/dev/null || git -C "$tmpseed" init -q
  git -C "$tmpseed" config user.email "t@t"
  git -C "$tmpseed" config user.name "t"
  # Force branch name 'work' so we don't depend on init.defaultBranch.
  git -C "$tmpseed" checkout -q -b work 2>/dev/null || true
  echo "remote v1" > "$tmpseed/f.txt"
  git -C "$tmpseed" add f.txt
  git -C "$tmpseed" commit -q -m remote-init
  git -C "$tmpseed" remote add origin "$tmpremote"
  git -C "$tmpseed" push -q origin work
  # Set bare HEAD so clone doesn't end up empty.
  git -C "$tmpremote" symbolic-ref HEAD refs/heads/work
  rm -rf "$tmpseed"

  git clone -q "$tmpremote" "$tmpgit"
  git -C "$tmpgit" config user.email "t@t"
  git -C "$tmpgit" config user.name "t"
  # Local commit makes HEAD diverge from upstream — without the fix this
  # would leak into the gate as "upstream:..." diff.
  echo "local v2" >> "$tmpgit/f.txt"
  git -C "$tmpgit" commit -q -am local-divergent

  # Nothing staged. With CCG_DIFF_CACHED_ONLY=1 we must get empty-diff,
  # NOT a fallback to upstream...HEAD or origin/HEAD...HEAD.
  local out_file="$tmpgit/diff.out"
  local capture_out capture_ec=0
  capture_out=$(
    cd "$tmpgit"
    export CCG_DIFF_CACHED_ONLY=1
    # shellcheck source=/dev/null
    source "$CCG_SH"
    ccg_diff_capture "$out_file"
  ) || capture_ec=$?

  rm -rf "$tmpremote" "$tmpgit"

  if [ "$capture_ec" = "1" ] && printf '%s' "$capture_out" | grep -q 'CCG_DIFF_FAIL=empty-diff'; then
    _pass "T6-cached-only-no-fallthrough"
  else
    _fail "T6-cached-only-no-fallthrough" "expected empty-diff (ec=1), got ec=$capture_ec out=$capture_out"
  fi
}
t6_cached_only_no_fallthrough

# ────────────────────────────────────────────────────────────
# Summary
# ────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
