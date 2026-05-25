#!/usr/bin/env bash
# tests/test_ccg_gate.sh — ccg_precommit_gate unit tests
# Uses mock codex/gemini binaries; no real API calls.
set -euo pipefail

CCG_SH="$(cd "$(dirname "$0")/.." && pwd)/ccg.sh"
PASS=0; FAIL=0

_pass() { printf 'PASS %s\n' "$1"; PASS=$((PASS+1)); }
_fail() { printf 'FAIL %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

_run_gate() {
  local verdict_codex="$1" verdict_gemini="$2" discuss_policy="${3:-allow}"
  local tmpbin
  tmpbin=$(mktemp -d)
  # mock codex
  cat > "$tmpbin/codex" <<EOF
#!/usr/bin/env bash
# write to --output-last-message file
for i in "\$@"; do :; done
# find the output file arg (after --output-last-message)
out=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "--output-last-message" ] && out="\$a"
  prev="\$a"
done
[ -n "\$out" ] && printf 'VERDICT: ${verdict_codex}\n' > "\$out"
EOF
  chmod +x "$tmpbin/codex"
  # mock gemini
  cat > "$tmpbin/gemini" <<EOF
#!/usr/bin/env bash
printf 'VERDICT: ${verdict_gemini}\n'
EOF
  chmod +x "$tmpbin/gemini"

  local tmpgit
  tmpgit=$(mktemp -d)
  git -C "$tmpgit" init -q
  git -C "$tmpgit" config user.email "test@test"
  git -C "$tmpgit" config user.name "test"
  echo "hello" > "$tmpgit/file.txt"
  git -C "$tmpgit" add file.txt
  git -C "$tmpgit" commit -q -m "init"
  echo "world" >> "$tmpgit/file.txt"

  local ec=0
  (
    cd "$tmpgit"
    export PATH="$tmpbin:$PATH"
    export CCG_GATE_DISCUSS="$discuss_policy"
    export CCG_NO_CACHE=1
    export CCG_NO_REPORT=1
    export CCG_NO_HISTORY=1
    export GEMINI_API_KEY=mock
    # shellcheck source=/dev/null
    source "$CCG_SH"
    ccg_precommit_gate 2>/dev/null
  ) || ec=$?

  rm -rf "$tmpbin" "$tmpgit"
  echo "$ec"
}

# ── Test 1: merge → exit 0 ──────────────────────────────────
ec=$(_run_gate merge merge)
[ "$ec" = "0" ] && _pass "merge→exit0" || _fail "merge→exit0" "got ec=$ec"

# ── Test 2: fix-required (codex) → exit 1 ──────────────────
ec=$(_run_gate fix-required merge)
[ "$ec" = "1" ] && _pass "fix-required-codex→exit1" || _fail "fix-required-codex→exit1" "got ec=$ec"

# ── Test 3: fix-required (gemini) → exit 1 ─────────────────
ec=$(_run_gate merge fix-required)
[ "$ec" = "1" ] && _pass "fix-required-gemini→exit1" || _fail "fix-required-gemini→exit1" "got ec=$ec"

# ── Test 4: discuss + allow → exit 0 ───────────────────────
ec=$(_run_gate discuss discuss allow)
[ "$ec" = "0" ] && _pass "discuss-allow→exit0" || _fail "discuss-allow→exit0" "got ec=$ec"

# ── Test 5: discuss + block → exit 1 ───────────────────────
ec=$(_run_gate discuss discuss block)
[ "$ec" = "1" ] && _pass "discuss-block→exit1" || _fail "discuss-block→exit1" "got ec=$ec"

# ── Test 6: CCG_GATE_OFFLINE=1 → always exit 0 ─────────────
tmpgit=$(mktemp -d)
git -C "$tmpgit" init -q
git -C "$tmpgit" config user.email "t@t" && git -C "$tmpgit" config user.name "t"
echo "x" > "$tmpgit/f.txt" && git -C "$tmpgit" add f.txt && git -C "$tmpgit" commit -q -m "i"
echo "y" >> "$tmpgit/f.txt"
ec=0
(
  cd "$tmpgit"
  export CCG_GATE_OFFLINE=1
  # shellcheck source=/dev/null
  source "$CCG_SH"
  ccg_precommit_gate 2>/dev/null
) || ec=$?
rm -rf "$tmpgit"
[ "$ec" = "0" ] && _pass "offline→exit0" || _fail "offline→exit0" "got ec=$ec"

# ── Test 7: git pre-commit hook install/uninstall ───────────
tmpgit=$(mktemp -d)
git -C "$tmpgit" init -q
git -C "$tmpgit" config user.email "t@t" && git -C "$tmpgit" config user.name "t"
(
  cd "$tmpgit"
  # shellcheck source=/dev/null
  source "$CCG_SH"
  out=$(ccg_install_hook)
  printf '%s\n' "$out" | grep -q 'CCG_HOOK_INSTALLED=git:' || { echo "install output missing"; exit 1; }
  hook_file="$tmpgit/.git/hooks/pre-commit"
  [ -x "$hook_file" ] || { echo "hook not executable"; exit 1; }
  grep -q 'ccg_precommit_gate' "$hook_file" || { echo "hook missing gate call"; exit 1; }
  out2=$(ccg_uninstall_hook)
  printf '%s\n' "$out2" | grep -qE 'CCG_HOOK_REMOVED|CCG_HOOK_RESTORED' || { echo "uninstall output missing"; exit 1; }
) && _pass "git-hook-install-uninstall" || _fail "git-hook-install-uninstall" "hook lifecycle failed"
rm -rf "$tmpgit"

# ── Summary ─────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
