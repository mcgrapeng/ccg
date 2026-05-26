#!/usr/bin/env bash
# tests/test_ccg_autocommit.sh — ccg_autocommit staged-only behavior tests
set -euo pipefail

CCG_SH="$(cd "$(dirname "$0")/.." && pwd)/ccg.sh"
PASS=0; FAIL=0
_pass() { printf 'PASS %s\n' "$1"; PASS=$((PASS+1)); }
_fail() { printf 'FAIL %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# Mock that always emits sentinel:merge
_make_merge_mocks() {
  local tmpbin="$1"
  cat > "$tmpbin/codex" <<'EOF'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "--output-last-message" ] && out="$a"; prev="$a"; done
prompt=$(cat)
sentinel_open=$(printf '%s' "$prompt" | grep -oE '<<<CCG_VERDICT_[A-F0-9]+:' | head -1)
[ -z "$sentinel_open" ] && sentinel_open='<<<CCG_VERDICT_FALLBACK:'
[ -n "$out" ] && printf 'ok\n%smerge>>>\n' "$sentinel_open" > "$out"
EOF
  chmod +x "$tmpbin/codex"
  cat > "$tmpbin/gemini" <<'EOF'
#!/usr/bin/env bash
prompt=$(cat)
sentinel_open=$(printf '%s' "$prompt" | grep -oE '<<<CCG_VERDICT_[A-F0-9]+:' | head -1)
[ -z "$sentinel_open" ] && sentinel_open='<<<CCG_VERDICT_FALLBACK:'
printf 'ok\n%smerge>>>\n' "$sentinel_open"
EOF
  chmod +x "$tmpbin/gemini"
}

# ── Test 1: nothing staged → refuses with helpful error ────
tmpbin=$(mktemp -d); _make_merge_mocks "$tmpbin"
tmpgit=$(mktemp -d)
git -C "$tmpgit" init -q
git -C "$tmpgit" config user.email "t@t" && git -C "$tmpgit" config user.name "t"
echo "v1" > "$tmpgit/f.txt" && git -C "$tmpgit" add f.txt && git -C "$tmpgit" commit -q -m i
echo "v2" >> "$tmpgit/f.txt"   # modified but NOT staged
ec=0
out=$(
  cd "$tmpgit"
  export PATH="$tmpbin:$PATH" GEMINI_API_KEY=mock CCG_NO_CACHE=1 CCG_NO_REPORT=1
  source "$CCG_SH"
  ccg_autocommit "test commit" 2>&1
) || ec=$?
case "$out" in
  *"nothing staged"*) [ "$ec" = "2" ] && _pass "refuses-when-nothing-staged" \
                       || _fail "refuses-when-nothing-staged" "got ec=$ec, expected 2" ;;
  *) _fail "refuses-when-nothing-staged" "missing 'nothing staged' message: $out" ;;
esac
rm -rf "$tmpbin" "$tmpgit"

# ── Test 2: staged file → commits only staged ──────────────
tmpbin=$(mktemp -d); _make_merge_mocks "$tmpbin"
tmpgit=$(mktemp -d)
git -C "$tmpgit" init -q
git -C "$tmpgit" config user.email "t@t" && git -C "$tmpgit" config user.name "t"
echo "v1" > "$tmpgit/f.txt" && git -C "$tmpgit" add f.txt && git -C "$tmpgit" commit -q -m i
# Two changes: one staged (intentional), one only worktree (unstaged — should NOT commit)
echo "intentional" > "$tmpgit/wanted.txt"
git -C "$tmpgit" add wanted.txt
echo "secret-key=fake-leaked-secret" > "$tmpgit/.env"   # should NOT be committed

(
  cd "$tmpgit"
  export PATH="$tmpbin:$PATH" GEMINI_API_KEY=mock CCG_NO_CACHE=1 CCG_NO_REPORT=1
  source "$CCG_SH"
  ccg_autocommit "add wanted.txt" 2>&1
) >/dev/null
# Inspect HEAD commit contents
committed=$(git -C "$tmpgit" show HEAD --stat --format=)
case "$committed" in
  *wanted.txt*) : ;;
  *) _fail "staged-only-commits-wanted" "wanted.txt missing from commit: $committed"; rm -rf "$tmpbin" "$tmpgit"; exit 1 ;;
esac
case "$committed" in
  *.env*) _fail "staged-only-skips-env" ".env was committed! diff: $committed"; rm -rf "$tmpbin" "$tmpgit"; exit 1 ;;
  *) _pass "staged-only-commits-wanted" ;;
esac
_pass "staged-only-skips-env"
rm -rf "$tmpbin" "$tmpgit"

# ── Test 3: CCG_AUTOCOMMIT_ALL=1 opts in to add -A behavior ─
tmpbin=$(mktemp -d); _make_merge_mocks "$tmpbin"
tmpgit=$(mktemp -d)
git -C "$tmpgit" init -q
git -C "$tmpgit" config user.email "t@t" && git -C "$tmpgit" config user.name "t"
echo "v1" > "$tmpgit/f.txt" && git -C "$tmpgit" add f.txt && git -C "$tmpgit" commit -q -m i
echo "new" > "$tmpgit/new.txt"   # unstaged
(
  cd "$tmpgit"
  export PATH="$tmpbin:$PATH" GEMINI_API_KEY=mock CCG_NO_CACHE=1 CCG_NO_REPORT=1
  export CCG_AUTOCOMMIT_ALL=1
  source "$CCG_SH"
  ccg_autocommit "all-mode" 2>&1
) >/dev/null
committed=$(git -C "$tmpgit" show HEAD --stat --format=)
case "$committed" in
  *new.txt*) _pass "CCG_AUTOCOMMIT_ALL-includes-unstaged" ;;
  *) _fail "CCG_AUTOCOMMIT_ALL-includes-unstaged" "new.txt missing: $committed" ;;
esac
rm -rf "$tmpbin" "$tmpgit"

# ── Test 4: gate rejects → no commit ────────────────────────
tmpbin=$(mktemp -d)
# Mock that emits fix-required
cat > "$tmpbin/codex" <<'EOF'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "--output-last-message" ] && out="$a"; prev="$a"; done
prompt=$(cat)
sentinel_open=$(printf '%s' "$prompt" | grep -oE '<<<CCG_VERDICT_[A-F0-9]+:' | head -1)
[ -n "$out" ] && printf '%sfix-required>>>\n' "$sentinel_open" > "$out"
EOF
chmod +x "$tmpbin/codex"
cat > "$tmpbin/gemini" <<'EOF'
#!/usr/bin/env bash
prompt=$(cat)
sentinel_open=$(printf '%s' "$prompt" | grep -oE '<<<CCG_VERDICT_[A-F0-9]+:' | head -1)
printf '%sfix-required>>>\n' "$sentinel_open"
EOF
chmod +x "$tmpbin/gemini"
tmpgit=$(mktemp -d)
git -C "$tmpgit" init -q
git -C "$tmpgit" config user.email "t@t" && git -C "$tmpgit" config user.name "t"
echo "v1" > "$tmpgit/f.txt" && git -C "$tmpgit" add f.txt && git -C "$tmpgit" commit -q -m i
echo "bad" > "$tmpgit/bad.js" && git -C "$tmpgit" add bad.js
sha_before=$(git -C "$tmpgit" rev-parse HEAD)
ec=0
(
  cd "$tmpgit"
  export PATH="$tmpbin:$PATH" GEMINI_API_KEY=mock CCG_NO_CACHE=1 CCG_NO_REPORT=1
  source "$CCG_SH"
  ccg_autocommit "bad code" 2>/dev/null
) || ec=$?
sha_after=$(git -C "$tmpgit" rev-parse HEAD)
[ "$ec" -ne 0 ] && [ "$sha_before" = "$sha_after" ] \
  && _pass "gate-rejects-no-commit" \
  || _fail "gate-rejects-no-commit" "ec=$ec, sha-changed=$([ "$sha_before" != "$sha_after" ] && echo yes || echo no)"
rm -rf "$tmpbin" "$tmpgit"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
