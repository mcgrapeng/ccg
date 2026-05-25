#!/usr/bin/env bash
# tests/test_ccg_svn.sh — SVN adapter regression tests
# Skipped automatically if svn/svnadmin are not installed.
set -euo pipefail

CCG_SH="$(cd "$(dirname "$0")/.." && pwd)/ccg.sh"
PASS=0; FAIL=0

_pass() { printf 'PASS %s\n' "$1"; PASS=$((PASS+1)); }
_fail() { printf 'FAIL %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

if ! command -v svn >/dev/null 2>&1 || ! command -v svnadmin >/dev/null 2>&1; then
  printf 'SKIP: svn/svnadmin not installed\n'
  exit 0
fi

# ── Setup: create a temp svn repo + working copy ────────────
REPO=$(mktemp -d)
WC=$(mktemp -d)
WC=$(cd "$WC" && pwd -P)   # resolve macOS /var → /private/var symlink
svnadmin create "$REPO"
svn checkout "file://$REPO" "$WC" -q

# Initial commit
echo "hello" > "$WC/file.txt"
svn add "$WC/file.txt" -q
svn commit "$WC" -m "init" -q

# Modify file (uncommitted working-copy change)
echo "world" >> "$WC/file.txt"

_cleanup() { rm -rf "$REPO" "$WC"; }
trap _cleanup EXIT

# ── Test 1: _ccg_vcs_detect returns svn ─────────────────────
result=$(cd "$WC" && bash -c "source '$CCG_SH'; _ccg_vcs_detect")
[ "$result" = "svn" ] && _pass "vcs_detect=svn" || _fail "vcs_detect=svn" "got: $result"

# ── Test 2: _ccg_vcs_root returns wc root ───────────────────
result=$(cd "$WC" && bash -c "source '$CCG_SH'; _ccg_vcs_root")
[ "$result" = "$WC" ] && _pass "vcs_root=wc" || _fail "vcs_root=wc" "got: $result"

# ── Test 3: _ccg_vcs_info has sha=r<N> form ─────────────────
result=$(cd "$WC" && bash -c "source '$CCG_SH'; _ccg_vcs_info")
printf '%s\n' "$result" | grep -qE '^sha=r[0-9]+' \
  && _pass "vcs_info sha=rN" || _fail "vcs_info sha=rN" "got: $result"

# ── Test 4: ccg_diff_capture produces git-format diff ───────
tmpout=$(mktemp)
result=$(cd "$WC" && bash -c "source '$CCG_SH'; ccg_diff_capture '$tmpout'")
printf '%s\n' "$result" | grep -q '^CCG_DIFF_OK=' \
  && _pass "diff_capture ok" || _fail "diff_capture ok" "got: $result"
grep -q '^diff --git ' "$tmpout" \
  && _pass "diff is git-format" || _fail "diff is git-format" "no 'diff --git' header in output"
rm -f "$tmpout"

# ── Test 5: ccg_risk_score parses svn diff correctly ────────
tmpout=$(mktemp)
cd "$WC" && bash -c "source '$CCG_SH'; ccg_diff_capture '$tmpout'" >/dev/null
result=$(bash -c "source '$CCG_SH'; ccg_risk_score '$tmpout'")
printf '%s\n' "$result" | grep -q '^CCG_RISK_SCORE=' \
  && _pass "risk_score parses svn diff" || _fail "risk_score parses svn diff" "got: $result"
rm -f "$tmpout"

# ── Test 6: ccg_ledger_record stores r<N> as sha ────────────
tmpout=$(mktemp)
tmpworkdir=$(mktemp -d)
cd "$WC" && bash -c "source '$CCG_SH'; ccg_diff_capture '$tmpout'" >/dev/null
cp "$tmpout" "$tmpworkdir/diff.txt"
printf 'gate verdict: merge\n' > "$tmpworkdir/synthesis.txt"
ledger=$(mktemp)
result=$(cd "$WC" && bash -c "
  source '$CCG_SH'
  CCG_LEDGER_LOG='$ledger' ccg_ledger_record '$tmpworkdir'
")
printf '%s\n' "$result" | grep -q '^CCG_LEDGER_OK=' \
  && _pass "ledger_record ok" || _fail "ledger_record ok" "got: $result"
grep -qE '"sha":"r[0-9]+"' "$ledger" \
  && _pass "ledger sha=rN" || _fail "ledger sha=rN" "ledger content: $(cat "$ledger")"
rm -f "$tmpout" "$ledger" && rm -rf "$tmpworkdir"

# ── Test 7: ccg_persist_report writes to wc-root/.ccg/reports ──
tmpworkdir=$(mktemp -d)
tmpout=$(mktemp)
cd "$WC" && bash -c "source '$CCG_SH'; ccg_diff_capture '$tmpout'" >/dev/null
cp "$tmpout" "$tmpworkdir/diff.txt"
printf 'gate verdict: merge\n' > "$tmpworkdir/synthesis.txt"
result=$(cd "$WC" && bash -c "
  source '$CCG_SH'
  CCG_NO_REPORT=0 ccg_persist_report '$tmpworkdir'
")
printf '%s\n' "$result" | grep -q '^CCG_REPORT_OK=' \
  && _pass "persist_report ok" || _fail "persist_report ok" "got: $result"
report_path=$(printf '%s\n' "$result" | grep '^CCG_REPORT_OK=' | cut -d= -f2-)
[[ "$report_path" == "$WC/.ccg/reports/"* ]] \
  && _pass "report in wc-root" || _fail "report in wc-root" "path: $report_path"
rm -f "$tmpout" && rm -rf "$tmpworkdir" "$WC/.ccg"

# ── Test 8: ccg_install_hook writes .ccg-precommit-hook.sh ──
result=$(cd "$WC" && bash -c "source '$CCG_SH'; ccg_install_hook")
printf '%s\n' "$result" | grep -q 'CCG_HOOK_INSTALLED=svn:' \
  && _pass "install_hook svn" || _fail "install_hook svn" "got: $result"
[ -x "$WC/.ccg-precommit-hook.sh" ] \
  && _pass "hook is executable" || _fail "hook is executable" "not found or not executable"

# ── Test 9: ccg_uninstall_hook removes the hook ─────────────
result=$(cd "$WC" && bash -c "source '$CCG_SH'; ccg_uninstall_hook")
printf '%s\n' "$result" | grep -q 'CCG_HOOK_REMOVED=' \
  && _pass "uninstall_hook svn" || _fail "uninstall_hook svn" "got: $result"
[ ! -f "$WC/.ccg-precommit-hook.sh" ] \
  && _pass "hook removed" || _fail "hook removed" "file still exists"

# ── Summary ─────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
