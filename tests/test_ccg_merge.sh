#!/usr/bin/env bash
# tests/test_ccg_merge.sh — ccg_merge unit tests with mock codex/gemini
set -euo pipefail

CCG_SH="$(cd "$(dirname "$0")/.." && pwd)/ccg.sh"
PASS=0; FAIL=0

_pass() { printf 'PASS %s\n' "$1"; PASS=$((PASS+1)); }
_fail() { printf 'FAIL %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# ── Mock binaries that auto-resolve conflicts ───────────────
_make_mocks() {
  local tmpbin="$1" mode="${2:-resolve}"
  cat > "$tmpbin/codex" <<EOF
#!/usr/bin/env bash
out=""; prev=""
for a in "\$@"; do
  [ "\$prev" = "--output-last-message" ] && out="\$a"
  prev="\$a"
done
if [ -n "\$out" ]; then
  if [ "$mode" = "needs_human" ]; then
    printf 'NEEDS_HUMAN_DECISION\n' > "\$out"
  else
    printf 'RESOLVED_BY_AI\nCONFIDENCE: high\n' > "\$out"
  fi
fi
EOF
  chmod +x "$tmpbin/codex"
  cat > "$tmpbin/gemini" <<EOF
#!/usr/bin/env bash
if [ "$mode" = "needs_human" ]; then
  printf 'NEEDS_HUMAN_DECISION\n'
else
  printf 'RESOLVED_BY_AI\nCONFIDENCE: high\n'
fi
EOF
  chmod +x "$tmpbin/gemini"
}

# ── Setup: create a git repo with two branches that conflict ──
_setup_conflict_repo() {
  local repo
  repo=$(mktemp -d)
  repo=$(cd "$repo" && pwd -P)
  cd "$repo"
  git init -q
  git config user.email "test@test"
  git config user.name "test"
  printf 'line1\nline2\nline3\n' > file.txt
  git add file.txt
  git commit -q -m "init"

  # Create main branch baseline
  git branch -M main

  # Branch A: changes line2
  git checkout -b feature -q
  printf 'line1\nFEATURE_CHANGE\nline3\n' > file.txt
  git commit -q -am "feature change"

  # Back to main, conflicting change on line2
  git checkout main -q
  printf 'line1\nMAIN_CHANGE\nline3\n' > file.txt
  git commit -q -am "main change"

  # NEW SEMANTICS: user stands on feature, merges INTO main
  git checkout feature -q
  echo "$repo"
}

# ── Test 1: clean merge (no conflicts) ─────────────────────
tmpbin=$(mktemp -d)
_make_mocks "$tmpbin" resolve
repo=$(mktemp -d) && repo=$(cd "$repo" && pwd -P)
(
  cd "$repo"
  git init -q
  git config user.email "t@t" && git config user.name "t"
  echo "v1" > f.txt && git add f.txt && git commit -q -m "init"
  git branch -M main
  git checkout -b feature -q
  echo "v2" > g.txt && git add g.txt && git commit -q -m "add g"
  # NEW SEMANTICS: stay on feature, merge INTO main
  export PATH="$tmpbin:$PATH"
  export GEMINI_API_KEY=mock CCG_NO_CACHE=1 CCG_NO_REPORT=1
  # shellcheck source=/dev/null
  source "$CCG_SH"
  out=$(ccg_merge main 2>&1)
  printf '%s\n' "$out" | grep -q 'CCG_MERGE_RESULT=clean' \
    && printf '%s\n' "$out" | grep -q 'CCG_MERGE_CONFLICTS=0' \
    || { echo "expected clean merge, got: $out"; exit 1; }
  # Should be on main now (target branch)
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] \
    || { echo "expected to be on main, got: $(git rev-parse --abbrev-ref HEAD)"; exit 1; }
) && _pass "clean-merge" || _fail "clean-merge" "see output"
rm -rf "$tmpbin" "$repo"

# ── Test 2: conflict merge with AI resolution ──────────────
tmpbin=$(mktemp -d)
_make_mocks "$tmpbin" resolve
repo=$(_setup_conflict_repo)
(
  cd "$repo"
  export PATH="$tmpbin:$PATH"
  export GEMINI_API_KEY=mock CCG_NO_CACHE=1 CCG_NO_REPORT=1
  # shellcheck source=/dev/null
  source "$CCG_SH"
  out=$(ccg_merge main 2>&1)
  printf '%s\n' "$out" | grep -q 'CCG_MERGE_RESULT=conflicts' \
    || { echo "expected conflict result, got: $out"; exit 1; }
  printf '%s\n' "$out" | grep -q 'CCG_MERGE_COMMITTED=1' \
    || { echo "expected committed, got: $out"; exit 1; }
  # File should contain RESOLVED_BY_AI (the mock output)
  grep -q 'RESOLVED_BY_AI' file.txt \
    || { echo "expected file to have AI resolution, got: $(cat file.txt)"; exit 1; }
  # Markers must be gone
  grep -qE '^(<{7}|>{7}|={7})' file.txt \
    && { echo "conflict markers should be removed"; exit 1; }
  true
) && _pass "conflict-ai-resolved" || _fail "conflict-ai-resolved" "see output"
rm -rf "$tmpbin" "$repo"

# ── Test 3: NEEDS_HUMAN_DECISION blocks commit ─────────────
tmpbin=$(mktemp -d)
_make_mocks "$tmpbin" needs_human
repo=$(_setup_conflict_repo)
(
  cd "$repo"
  export PATH="$tmpbin:$PATH"
  export GEMINI_API_KEY=mock CCG_NO_CACHE=1 CCG_NO_REPORT=1
  # shellcheck source=/dev/null
  source "$CCG_SH"
  out=$(ccg_merge main 2>&1)
  printf '%s\n' "$out" | grep -q 'CCG_MERGE_BLOCKED=needs-human' \
    || { echo "expected blocked, got: $out"; exit 1; }
  # Backup branch should exist
  git branch | grep -q 'ccg-backup/' \
    || { echo "backup branch missing"; exit 1; }
) && _pass "needs-human-blocks" || _fail "needs-human-blocks" "see output"
rm -rf "$tmpbin" "$repo"

# ── Test 4: dirty working tree refused ─────────────────────
repo=$(mktemp -d) && repo=$(cd "$repo" && pwd -P)
(
  cd "$repo"
  git init -q && git config user.email "t@t" && git config user.name "t"
  echo "v1" > f.txt && git add f.txt && git commit -q -m "init"
  git branch -M main
  git checkout -b feature -q
  echo "v2" > g.txt && git add g.txt && git commit -q -m "add g"
  echo "dirty" >> g.txt   # uncommitted change on feature
  # shellcheck source=/dev/null
  source "$CCG_SH"
  out=$(ccg_merge main 2>&1)
  printf '%s\n' "$out" | grep -q 'CCG_MERGE_FAIL=dirty-working-tree' \
    || { echo "expected dirty-tree rejection, got: $out"; exit 1; }
) && _pass "dirty-tree-rejected" || _fail "dirty-tree-rejected" "see output"
rm -rf "$repo"

# ── Test 5: dry-run leaves repo unchanged ──────────────────
tmpbin=$(mktemp -d)
_make_mocks "$tmpbin" resolve
repo=$(_setup_conflict_repo)
(
  cd "$repo"
  export PATH="$tmpbin:$PATH"
  export GEMINI_API_KEY=mock CCG_NO_CACHE=1 CCG_NO_REPORT=1
  export CCG_MERGE_DRY_RUN=1
  sha_before=$(git rev-parse HEAD)
  # shellcheck source=/dev/null
  source "$CCG_SH"
  ccg_merge main >/dev/null 2>&1 || true
  sha_after=$(git rev-parse HEAD)
  [ "$sha_before" = "$sha_after" ] \
    || { echo "dry-run should not commit, before=$sha_before after=$sha_after"; exit 1; }
) && _pass "dry-run-no-commit" || _fail "dry-run-no-commit" "see output"
rm -rf "$tmpbin" "$repo"

# ── Test 6: backup branch created ──────────────────────────
tmpbin=$(mktemp -d)
_make_mocks "$tmpbin" resolve
repo=$(_setup_conflict_repo)
(
  cd "$repo"
  export PATH="$tmpbin:$PATH"
  export GEMINI_API_KEY=mock CCG_NO_CACHE=1 CCG_NO_REPORT=1
  export CCG_MERGE_KEEP_BACKUP=1
  # shellcheck source=/dev/null
  source "$CCG_SH"
  ccg_merge main >/dev/null 2>&1
  # With CCG_MERGE_KEEP_BACKUP=1 the backup branch must survive the merge.
  git branch | grep -q 'ccg-backup/main-' \
    || { echo "backup branch not created"; git branch; exit 1; }
) && _pass "backup-branch-created" || _fail "backup-branch-created" "see output"
rm -rf "$tmpbin" "$repo"

# ── Test 7: detached HEAD rejected ──────────────────────────
repo=$(mktemp -d) && repo=$(cd "$repo" && pwd -P)
(
  cd "$repo"
  git init -q && git config user.email "t@t" && git config user.name "t"
  echo "v1" > f.txt && git add f.txt && git commit -q -m init
  git branch -M main
  echo "v2" > f.txt && git commit -q -am v2
  git checkout HEAD~1 -q 2>/dev/null   # detached
  source "$CCG_SH"
  out=$(ccg_merge main 2>&1)
  printf '%s\n' "$out" | grep -q 'CCG_MERGE_FAIL=detached-head' \
    || { echo "expected detached-head rejection, got: $out"; exit 1; }
) && _pass "detached-head-rejected" || _fail "detached-head-rejected" "see output"
rm -rf "$repo"

# ── Test 8: binary file conflict → NEEDS_HUMAN, no git add ──
tmpbin=$(mktemp -d); _make_mocks "$tmpbin" resolve
repo=$(mktemp -d) && repo=$(cd "$repo" && pwd -P)
(
  cd "$repo"
  git init -q && git config user.email "t@t" && git config user.name "t"
  # Create a "binary" file with NUL bytes
  printf 'header\x00\x01\x02binary\n' > bin.dat
  git add bin.dat && git commit -q -m "init bin" && git branch -M main
  git checkout -b feature -q
  printf 'header\x00\x01\x02FEATURE\n' > bin.dat
  git commit -q -am feature
  git checkout main -q
  printf 'header\x00\x01\x02MAIN\n' > bin.dat
  git commit -q -am main
  git checkout feature -q
  export PATH="$tmpbin:$PATH"
  export GEMINI_API_KEY=mock CCG_NO_CACHE=1 CCG_NO_REPORT=1 CCG_MERGE_NO_FETCH=1
  source "$CCG_SH"
  out=$(ccg_merge main 2>&1)
  printf '%s\n' "$out" | grep -q 'CCG_MERGE_BLOCKED=needs-human' \
    || { echo "expected needs-human, got: $out"; exit 1; }
  printf '%s\n' "$out" | grep -q 'bin.dat\[binary\]' \
    || { echo "expected bin.dat marked binary, got: $out"; exit 1; }
  # Binary file must remain unmerged (would falsely mark resolved if we git add'd it)
  git status --porcelain=v2 | awk '$1=="u"' | grep -q bin.dat \
    || { echo "binary conflict file should stay unmerged, status: $(git status --porcelain=v2)"; exit 1; }
  true
) && _pass "binary-conflict-needs-human" || _fail "binary-conflict-needs-human" "see output"
rm -rf "$tmpbin" "$repo"

# ── Test 9: delete/modify conflict → NEEDS_HUMAN, no git add ──
tmpbin=$(mktemp -d); _make_mocks "$tmpbin" resolve
repo=$(mktemp -d) && repo=$(cd "$repo" && pwd -P)
(
  cd "$repo"
  git init -q && git config user.email "t@t" && git config user.name "t"
  printf 'original\n' > doc.md
  git add doc.md && git commit -q -m init && git branch -M main
  git checkout -b feature -q
  printf 'modified by feature\n' > doc.md
  git commit -q -am "feature edits doc"
  git checkout main -q
  git rm -q doc.md
  git commit -q -m "main deletes doc"
  git checkout feature -q
  export PATH="$tmpbin:$PATH"
  export GEMINI_API_KEY=mock CCG_NO_CACHE=1 CCG_NO_REPORT=1 CCG_MERGE_NO_FETCH=1
  source "$CCG_SH"
  out=$(ccg_merge main 2>&1)
  printf '%s\n' "$out" | grep -q 'CCG_MERGE_BLOCKED=needs-human' \
    || { echo "expected needs-human for delete/modify, got: $out"; exit 1; }
  # The conflict file must NOT be staged
  git status --porcelain=v2 | awk '$1=="u"' | grep -q doc.md \
    || { echo "expected doc.md to stay unmerged"; exit 1; }
) && _pass "delete-modify-needs-human" || _fail "delete-modify-needs-human" "see output"
rm -rf "$tmpbin" "$repo"

# ── Test 10: safe_name collision (a/b.txt vs a_b.txt) ───────
tmpbin=$(mktemp -d); _make_mocks "$tmpbin" resolve
repo=$(mktemp -d) && repo=$(cd "$repo" && pwd -P)
(
  cd "$repo"
  git init -q && git config user.email "t@t" && git config user.name "t"
  mkdir a
  printf 'A1\n' > a/b.txt
  printf 'A2\n' > a_b.txt
  git add . && git commit -q -m init && git branch -M main
  git checkout -b feature -q
  printf 'FEAT A/B\n' > a/b.txt
  printf 'FEAT A_B\n' > a_b.txt
  git commit -q -am feature
  git checkout main -q
  printf 'MAIN A/B\n' > a/b.txt
  printf 'MAIN A_B\n' > a_b.txt
  git commit -q -am main
  git checkout feature -q
  export PATH="$tmpbin:$PATH"
  export GEMINI_API_KEY=mock CCG_NO_CACHE=1 CCG_NO_REPORT=1 CCG_MERGE_NO_FETCH=1
  source "$CCG_SH"
  out=$(ccg_merge main 2>&1)
  # Both files should be resolved, neither lost. Old code would map both
  # to same safe_name "a_b.txt" and one resolution would overwrite the other.
  printf '%s\n' "$out" | grep -q 'CCG_MERGE_COMMITTED=1' \
    || { echo "expected committed, got: $out"; exit 1; }
  [ -f a/b.txt ] && [ -f a_b.txt ] \
    || { echo "both files must survive"; exit 1; }
  grep -q 'RESOLVED_BY_AI' a/b.txt && grep -q 'RESOLVED_BY_AI' a_b.txt \
    || { echo "both files must be resolved independently, got:"; cat a/b.txt; echo "---"; cat a_b.txt; exit 1; }
) && _pass "safe-name-collision-protected" || _fail "safe-name-collision-protected" "see output"
rm -rf "$tmpbin" "$repo"

# ── Test 11: in-progress operation (mid-merge) rejected ─────
repo=$(mktemp -d) && repo=$(cd "$repo" && pwd -P)
(
  cd "$repo"
  git init -q && git config user.email "t@t" && git config user.name "t"
  echo "v1" > f.txt && git add f.txt && git commit -q -m init
  git branch -M main
  git checkout -b feature -q
  echo "feat" > f.txt && git commit -q -am feature
  git checkout main -q
  echo "main" > f.txt && git commit -q -am main
  # Start a merge that will conflict (leaving MERGE_HEAD)
  git merge feature 2>/dev/null || true
  source "$CCG_SH"
  out=$(ccg_merge feature 2>&1 || true)
  # Should detect mid-merge state
  printf '%s\n' "$out" | grep -qE 'CCG_MERGE_FAIL=(in-progress-operation|dirty-working-tree|same-branch)' \
    || { echo "expected in-progress detection, got: $out"; exit 1; }
) && _pass "in-progress-operation-rejected" || _fail "in-progress-operation-rejected" "see output"
rm -rf "$repo"

# ── Test 12: fetch + pull --ff-only when local target is behind ──
tmpbin=$(mktemp -d); _make_mocks "$tmpbin" resolve
remote=$(mktemp -d) && remote=$(cd "$remote" && pwd -P)
clone1=$(mktemp -d) && clone1=$(cd "$clone1" && pwd -P)
clone2=$(mktemp -d) && clone2=$(cd "$clone2" && pwd -P)
git init --bare -q "$remote/origin.git"
# clone1: bootstrap main on remote
(
  set -e
  cd "$clone1"
  git clone -q "$remote/origin.git" .
  git config user.email "t@t"
  git config user.name "t"
  echo "v1" > f.txt
  git checkout -b main -q
  git add f.txt
  git commit -q -m "init"
  git push -q -u origin main
) || { rm -rf "$tmpbin" "$remote" "$clone1" "$clone2"; _fail "fetch-pull-ff-only" "clone1 setup failed"; }
# clone2: develop a feature
(
  set -e
  cd "$clone2"
  git clone -q "$remote/origin.git" .
  git config user.email "t@t"
  git config user.name "t"
  # Establish local main tracking origin/main, then branch off it.
  # Without this, `git checkout -b feature` on an empty clone creates
  # an orphan branch with no common ancestor → merge would fail with
  # "unrelated histories".
  git checkout -b main origin/main -q
  git checkout -b feature -q
  echo "feature-add" > new.txt
  git add new.txt
  git commit -q -m "feature work"
) || { rm -rf "$tmpbin" "$remote" "$clone1" "$clone2"; _fail "fetch-pull-ff-only" "clone2 setup failed"; }
# Someone else advances origin/main
(
  set -e
  cd "$clone1"
  echo "v2-other-dev" >> f.txt
  git commit -q -am "advance main"
  git push -q origin main
) || { rm -rf "$tmpbin" "$remote" "$clone1" "$clone2"; _fail "fetch-pull-ff-only" "advance failed"; }
# Now ccg_merge in clone2 must auto-fetch+pull before merging
(
  cd "$clone2"
  export PATH="$tmpbin:$PATH"
  export GEMINI_API_KEY=mock CCG_NO_CACHE=1 CCG_NO_REPORT=1
  # shellcheck source=/dev/null
  source "$CCG_SH"
  out=$(ccg_merge main 2>&1) || true
  case "$out" in
    *CCG_MERGE_PULLED=*) : ;;
    *) echo "expected auto-pull, got:"; printf '%s\n' "$out"; exit 1 ;;
  esac
  main_log=$(git log --oneline main 2>/dev/null)
  case "$main_log" in
    *"feature work"*) : ;;
    *) echo "feature missing from main."; echo "log:"; printf '%s\n' "$main_log"; exit 1 ;;
  esac
  case "$main_log" in
    *"advance main"*) : ;;
    *) echo "remote commit missing, log:"; printf '%s\n' "$main_log"; exit 1 ;;
  esac
) && _pass "fetch-pull-ff-only" || _fail "fetch-pull-ff-only" "see output"
rm -rf "$tmpbin" "$remote" "$clone1" "$clone2"

# ── Summary ─────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
