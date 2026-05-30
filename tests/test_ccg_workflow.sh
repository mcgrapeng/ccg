#!/usr/bin/env bash
# tests/test_ccg_workflow.sh — coverage for the standalone CLI orchestration in
# ccg-workflow.sh (ccg_review → ccg_commit → ccg_push_check).
#
# These flows had NO direct coverage and are where two production bugs lived:
#   B2: ccg_push_check analyzed + prompted but never ran `git push`.
#   B4: ccg_commit's auto-add used `git diff --quiet`, which is blind to
#       untracked files — a brand-new file would never be staged.
#
# All tests use mock codex/gemini binaries; no real API calls.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORKFLOW="$ROOT/ccg-workflow.sh"
[ -r "$WORKFLOW" ] || { echo "FATAL: $WORKFLOW not found" >&2; exit 2; }

PASS=0; FAIL=0
_pass() { printf 'PASS %s\n' "$1"; PASS=$((PASS+1)); }
_fail() { printf 'FAIL %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# Shared isolation so the suite never touches the user's real XDG data.
TEST_HOME=$(mktemp -d)
export CCG_CACHE_DIR="$TEST_HOME/cache"
export CCG_USAGE_LOG="$TEST_HOME/usage.log"
export CCG_LEDGER_LOG="$TEST_HOME/ledger.jsonl"
export CCG_NO_REPORT=1 CCG_NO_HISTORY=1 CCG_NO_CACHE=1
trap 'rm -rf "$TEST_HOME"' EXIT

# Mock codex: review prompt → benign findings; synthesis prompt → VERDICT: merge.
# Mock gemini: benign findings on stdout.
_make_mocks() {
  local tmpbin="$1"
  cat > "$tmpbin/codex" <<'EOF'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "--output-last-message" ] && out="$a"; prev="$a"; done
prompt=$(cat)
[ -z "$out" ] && exit 0
if printf '%s' "$prompt" | grep -q 'meta-reviewer'; then
  printf '1. CLASSIFICATION: AGREEMENT\n2. KEY FINDINGS: none\n3. RECOMMENDATION: safe\n4. VERDICT: merge\n' > "$out"
else
  printf 'Reviewed the diff. No blocking issues found.\n' > "$out"
fi
EOF
  chmod +x "$tmpbin/codex"
  cat > "$tmpbin/gemini" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'Reviewed the diff. Looks reasonable; nothing blocking.\n'
EOF
  chmod +x "$tmpbin/gemini"
}

# ── Test 1 (B4): ccg_commit auto-stages an untracked-only change ────
t1_commit_untracked() {
  local tmpgit; tmpgit=$(mktemp -d)
  git -C "$tmpgit" init -q -b main
  git -C "$tmpgit" config user.email t@t; git -C "$tmpgit" config user.name t
  echo base > "$tmpgit/base.txt"; git -C "$tmpgit" add -A; git -C "$tmpgit" commit -q -m init
  echo "brand new" > "$tmpgit/newfile.txt"   # untracked, no tracked changes
  (
    cd "$tmpgit"
    export CCG_REVIEW=off
    . "$WORKFLOW"
    ccg_commit "feat: add newfile" >/dev/null 2>&1
  )
  if git -C "$tmpgit" ls-files --error-unmatch newfile.txt >/dev/null 2>&1 \
     && git -C "$tmpgit" log --oneline -1 | grep -q newfile; then
    _pass "B4-commit-auto-stages-untracked-file"
  else
    _fail "B4-commit-auto-stages-untracked-file" "newfile.txt not committed"
  fi
  rm -rf "$tmpgit"
}

# ── Test 2: ccg_commit refuses with no prior review (review enabled) ─
t2_commit_requires_review() {
  local tmpgit; tmpgit=$(mktemp -d)
  git -C "$tmpgit" init -q -b main
  git -C "$tmpgit" config user.email t@t; git -C "$tmpgit" config user.name t
  echo base > "$tmpgit/base.txt"; git -C "$tmpgit" add -A; git -C "$tmpgit" commit -q -m init
  echo change >> "$tmpgit/base.txt"
  local ec=0 out
  out=$(
    cd "$tmpgit"
    unset CCG_REVIEW
    . "$WORKFLOW"
    ccg_commit "feat: x" 2>&1
  ) || ec=$?
  if [ "$ec" = "1" ] && printf '%s' "$out" | grep -q 'No prior review'; then
    _pass "commit-requires-prior-review"
  else
    _fail "commit-requires-prior-review" "ec=$ec out=$out"
  fi
  rm -rf "$tmpgit"
}

# ── Test 3: review → state file → commit (happy path) ───────────────
t3_review_then_commit() {
  local tmpbin; tmpbin=$(mktemp -d); _make_mocks "$tmpbin"
  local tmpgit; tmpgit=$(mktemp -d)
  git -C "$tmpgit" init -q -b main
  git -C "$tmpgit" config user.email t@t; git -C "$tmpgit" config user.name t
  echo base > "$tmpgit/base.txt"; git -C "$tmpgit" add -A; git -C "$tmpgit" commit -q -m init
  printf 'line2\n' >> "$tmpgit/base.txt"   # worktree change to review
  local sha_before; sha_before=$(git -C "$tmpgit" rev-parse HEAD)
  (
    cd "$tmpgit"
    export PATH="$tmpbin:$PATH" GEMINI_API_KEY=mock
    unset CCG_REVIEW CCG_MODE CCG_PROVIDERS BAILIAN_API_KEY ANTHROPIC_API_KEY CLAUDE_API_KEY
    . "$WORKFLOW"
    ccg_review            >/dev/null 2>&1
    ccg_commit "feat: line2" >/dev/null 2>&1
  )
  local sha_after; sha_after=$(git -C "$tmpgit" rev-parse HEAD)
  if [ "$sha_before" != "$sha_after" ] \
     && git -C "$tmpgit" log --oneline -1 | grep -q 'line2'; then
    _pass "review-then-commit-happy-path"
  else
    _fail "review-then-commit-happy-path" "no commit produced (before=$sha_before after=$sha_after)"
  fi
  rm -rf "$tmpbin" "$tmpgit"
}

# ── Test 4 (B2): ccg_push_check actually pushes on approval ──────────
t4_push_on_approval() {
  local remote; remote=$(mktemp -d)/r.git; git init -q --bare "$remote"
  local tmpgit; tmpgit=$(mktemp -d)
  git -C "$tmpgit" init -q -b main
  git -C "$tmpgit" config user.email t@t; git -C "$tmpgit" config user.name t
  echo base > "$tmpgit/base.txt"; git -C "$tmpgit" add -A; git -C "$tmpgit" commit -q -m init
  git -C "$tmpgit" remote add origin "$remote"
  git -C "$tmpgit" push -q -u origin main
  echo more >> "$tmpgit/base.txt"; git -C "$tmpgit" commit -q -am "feat: more"
  local local_head; local_head=$(git -C "$tmpgit" rev-parse HEAD)
  (
    cd "$tmpgit"
    . "$WORKFLOW"
    printf 'y\n' | ccg_push_check origin main >/dev/null 2>&1
  )
  local remote_head; remote_head=$(git -C "$remote" rev-parse main 2>/dev/null)
  if [ "$remote_head" = "$local_head" ]; then
    _pass "B2-push-lands-on-remote-after-approval"
  else
    _fail "B2-push-lands-on-remote-after-approval" "remote=$remote_head local=$local_head"
  fi
  rm -rf "$tmpgit" "$(dirname "$remote")"
}

# ── Test 5 (B2): ccg_push_check does NOT push when cancelled ─────────
t5_push_cancel() {
  local remote; remote=$(mktemp -d)/r.git; git init -q --bare "$remote"
  local tmpgit; tmpgit=$(mktemp -d)
  git -C "$tmpgit" init -q -b main
  git -C "$tmpgit" config user.email t@t; git -C "$tmpgit" config user.name t
  echo base > "$tmpgit/base.txt"; git -C "$tmpgit" add -A; git -C "$tmpgit" commit -q -m init
  git -C "$tmpgit" remote add origin "$remote"
  git -C "$tmpgit" push -q -u origin main
  local remote_before; remote_before=$(git -C "$remote" rev-parse main)
  echo more >> "$tmpgit/base.txt"; git -C "$tmpgit" commit -q -am "feat: more"
  local ec=0
  (
    cd "$tmpgit"
    . "$WORKFLOW"
    printf 'n\n' | ccg_push_check origin main >/dev/null 2>&1
  ) || ec=$?
  local remote_after; remote_after=$(git -C "$remote" rev-parse main)
  if [ "$ec" = "1" ] && [ "$remote_before" = "$remote_after" ]; then
    _pass "B2-push-cancel-leaves-remote-untouched"
  else
    _fail "B2-push-cancel-leaves-remote-untouched" "ec=$ec before=$remote_before after=$remote_after"
  fi
  rm -rf "$tmpgit" "$(dirname "$remote")"
}

# ── Test 6: CCG_REVIEW=off makes review a no-op ─────────────────────
t6_review_off_noop() {
  local tmpgit; tmpgit=$(mktemp -d)
  git -C "$tmpgit" init -q -b main
  git -C "$tmpgit" config user.email t@t; git -C "$tmpgit" config user.name t
  echo base > "$tmpgit/base.txt"; git -C "$tmpgit" add -A; git -C "$tmpgit" commit -q -m init
  local out ec=0
  out=$(
    cd "$tmpgit"
    export CCG_REVIEW=off
    . "$WORKFLOW"
    ccg_review 2>&1
  ) || ec=$?
  if [ "$ec" = "0" ] && printf '%s' "$out" | grep -qi 'DISABLED'; then
    _pass "review-off-is-noop"
  else
    _fail "review-off-is-noop" "ec=$ec out=$out"
  fi
  rm -rf "$tmpgit"
}

# ── Test 7 (B11): review captures untracked files so commit's hash matches ──
# ccg review uses `git diff HEAD` scope; ccg commit stages with `git add -A`.
# A brand-new (untracked) file must be in the reviewed scope, otherwise the
# diff-hash gate rejects the commit with a misleading "re-run review" error.
t7_review_includes_untracked() {
  local tmpbin; tmpbin=$(mktemp -d); _make_mocks "$tmpbin"
  local tmpgit; tmpgit=$(mktemp -d)
  git -C "$tmpgit" init -q -b main
  git -C "$tmpgit" config user.email t@t; git -C "$tmpgit" config user.name t
  echo base > "$tmpgit/base.txt"; git -C "$tmpgit" add -A; git -C "$tmpgit" commit -q -m init
  printf 'line2\n' >> "$tmpgit/base.txt"      # tracked modification
  echo "new" > "$tmpgit/brandnew.txt"          # untracked new file
  (
    cd "$tmpgit"
    export PATH="$tmpbin:$PATH" GEMINI_API_KEY=mock
    unset CCG_REVIEW CCG_MODE CCG_PROVIDERS BAILIAN_API_KEY ANTHROPIC_API_KEY CLAUDE_API_KEY
    . "$WORKFLOW"
    ccg_review                 >/dev/null 2>&1
    ccg_commit "feat: both"    >/dev/null 2>&1
  )
  if git -C "$tmpgit" ls-files --error-unmatch brandnew.txt >/dev/null 2>&1 \
     && git -C "$tmpgit" log --oneline -1 | grep -q 'feat: both'; then
    _pass "B11-review-includes-untracked-so-commit-matches"
  else
    _fail "B11-review-includes-untracked-so-commit-matches" \
          "commit blocked by hash mismatch on untracked file"
  fi
  rm -rf "$tmpbin" "$tmpgit"
}

t1_commit_untracked
t2_commit_requires_review
t3_review_then_commit
t4_push_on_approval
t5_push_cancel
t6_review_off_noop
t7_review_includes_untracked

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
