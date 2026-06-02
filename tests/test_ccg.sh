#!/usr/bin/env bash
# test_ccg.sh — End-to-end regression + adversarial stress test for ccg.sh
# Designed to be run repeatedly; no external network calls except optional real-CLI tests.
#
# Usage:   bash tests/test_ccg.sh              # full suite (mocked CLIs)
#          REAL_CLI=1 bash tests/test_ccg.sh   # also run live codex/gemini calls
#          VERBOSE=1 bash tests/test_ccg.sh    # show per-test detail
#
# Exit code: 0 if all pass, 1 if any fail.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HELPER="$ROOT/ccg.sh"

[ -r "$HELPER" ] || { echo "FATAL: $HELPER not found" >&2; exit 2; }

# Test isolation: never touch the user's real ~/.ccg cache or usage log.
TEST_HOME=$(mktemp -d)
export CCG_CACHE_DIR="$TEST_HOME/cache"
export CCG_USAGE_LOG="$TEST_HOME/usage.log"
trap 'rm -rf "$TEST_HOME"' EXIT

PASS=0
FAIL=0
FAIL_NAMES=()
CURRENT=""
START_TS=$(date +%s)

_say() { [ "${VERBOSE:-0}" = "1" ] && echo "    $*" >&2 || true; }

t_start() {
  CURRENT="$1"
  printf '... %-72s' "$CURRENT"
}

t_pass() {
  echo "PASS"
  PASS=$((PASS + 1))
}

t_fail() {
  local reason="$*"
  echo "FAIL"
  echo "    $reason" >&2
  FAIL=$((FAIL + 1))
  FAIL_NAMES+=("$CURRENT")
}

assert_eq()    { if [ "$1" = "$2" ]; then t_pass; else t_fail "expected: $2 got: $1"; fi }
assert_ne()    { if [ "$1" != "$2" ]; then t_pass; else t_fail "expected != $2"; fi }
assert_match() { if printf '%s' "$1" | grep -qE -- "$2"; then t_pass; else t_fail "no match /$2/ in: $1"; fi }
assert_nomatch(){ if ! printf '%s' "$1" | grep -qE -- "$2"; then t_pass; else t_fail "unexpected match /$2/"; fi }
assert_dir()   { if [ -d "$1" ]; then t_pass; else t_fail "expected dir: $1"; fi }
assert_nodir() { if [ ! -d "$1" ]; then t_pass; else t_fail "dir should not exist: $1"; fi }
assert_file()  { if [ -f "$1" ]; then t_pass; else t_fail "expected file: $1"; fi }
assert_perm()  { local actual; actual=$(stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null); if [ "$actual" = "$2" ]; then t_pass; else t_fail "perm $2 expected, got $actual"; fi }

# --- Helper sourcing helper ----------------------------------------------------
fresh_source() {
  # Source helper in a clean function-only shell. We unset any prior cached fns.
  unset -f ccg_init ccg_preflight ccg_codex ccg_gemini ccg_cleanup _ccg_run_with_timeout _ccg_redact _ccg_pick_launcher 2>/dev/null || true
  # shellcheck disable=SC1090
  . "$HELPER"
}

# === 1. ccg_init basics ========================================================
t_start "1.1 ccg_init creates a writable mode-700 workdir"
fresh_source
out=$(ccg_init)
CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
assert_dir "$CCG_DIR"

t_start "1.2 ccg_init workdir permission is 700"
assert_perm "$CCG_DIR" 700

t_start "1.3 ccg_init basename starts with ccg."
base="${CCG_DIR##*/}"
case "$base" in ccg.*) t_pass ;; *) t_fail "basename: $base" ;; esac

t_start "1.4 ccg_init prints all required env paths"
for v in CCG_DIR CCG_CODEX_PROMPT CCG_GEMINI_PROMPT CCG_CODEX_RESULT CCG_GEMINI_RESULT CCG_CODEX_ERR CCG_GEMINI_ERR; do
  if ! echo "$out" | grep -q "^$v="; then t_fail "missing $v"; break; fi
done
[ "$FAIL" -eq 0 ] || true
case "$out" in *CCG_CODEX_ERR=*) t_pass ;; *) t_fail "missing CCG_CODEX_ERR in: $out" ;; esac

t_start "1.5 ccg_init two invocations produce DIFFERENT dirs (concurrency safety)"
out2=$(ccg_init)
CCG_DIR2=$(echo "$out2" | sed -n 's/^CCG_DIR=//p')
assert_ne "$CCG_DIR" "$CCG_DIR2"
ccg_cleanup "$CCG_DIR2" >/dev/null

t_start "1.6 ccg_init under broken TMPDIR falls back gracefully"
( export TMPDIR=/nonexistent/missing/path; fresh_source; out3=$(ccg_init 2>&1) ; \
  CCG_DIR3=$(echo "$out3" | sed -n 's/^CCG_DIR=//p'); \
  if [ -n "$CCG_DIR3" ] && [ -d "$CCG_DIR3" ]; then \
    rm -rf "$CCG_DIR3"; exit 0; \
  else exit 1; fi ) && t_pass || t_fail "ccg_init failed under broken TMPDIR (should fallback to /tmp)"

# === 2. ccg_cleanup safety =====================================================
t_start "2.1 ccg_cleanup removes a valid workdir"
fresh_source; out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
ccg_cleanup "$CCG_DIR" >/dev/null
assert_nodir "$CCG_DIR"

t_start "2.2 ccg_cleanup rejects empty arg"
result=$(ccg_cleanup "" 2>&1)
assert_match "$result" "skipped"

t_start "2.3 ccg_cleanup rejects relative path"
result=$(ccg_cleanup "tmp/ccg.evil" 2>&1)
assert_match "$result" "skipped"

t_start "2.4 ccg_cleanup rejects path with .. traversal"
mkdir -p /tmp/ccg.testtraversal/sub
result=$(ccg_cleanup "/tmp/ccg.testtraversal/../ccg.testtraversal" 2>&1)
assert_match "$result" "skipped"
[ -d /tmp/ccg.testtraversal ] && rm -rf /tmp/ccg.testtraversal

t_start "2.5 ccg_cleanup rejects basename NOT starting with ccg."
mkdir -p /tmp/notccg.fake
result=$(ccg_cleanup "/tmp/notccg.fake" 2>&1)
assert_match "$result" "skipped"
[ -d /tmp/notccg.fake ] && rm -rf /tmp/notccg.fake

t_start "2.6 ccg_cleanup rejects symlinked path"
mkdir -p /tmp/ccg.realdir
ln -sf /tmp/ccg.realdir /tmp/ccg.symlink
result=$(ccg_cleanup "/tmp/ccg.symlink" 2>&1)
assert_match "$result" "skipped"
[ -d /tmp/ccg.realdir ] && rm -rf /tmp/ccg.realdir
[ -L /tmp/ccg.symlink ] && rm -f /tmp/ccg.symlink

t_start "2.7 ccg_cleanup rejects path that exists but is NOT a directory"
touch /tmp/ccg.regularfile
result=$(ccg_cleanup "/tmp/ccg.regularfile" 2>&1)
assert_match "$result" "skipped"
[ -e /tmp/ccg.regularfile ] && rm -f /tmp/ccg.regularfile

t_start "2.8 ccg_cleanup with CCG_KEEP_ARTIFACTS=1 preserves dir"
fresh_source; out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
result=$(CCG_KEEP_ARTIFACTS=1 ccg_cleanup "$CCG_DIR" 2>&1)
if [ -d "$CCG_DIR" ] && echo "$result" | grep -q "skipped"; then t_pass; else t_fail "kept-dir or skipped-msg missing"; fi
rm -rf "$CCG_DIR"

t_start "2.9 ccg_cleanup tolerates trailing slash"
fresh_source; out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
ccg_cleanup "${CCG_DIR}/" >/dev/null
assert_nodir "$CCG_DIR"

t_start "2.10 ccg_cleanup rejects /tmp itself (basename != ccg.*)"
result=$(ccg_cleanup "/tmp" 2>&1)
assert_match "$result" "skipped"
[ -d /tmp ] && t_pass || t_fail "/tmp gone (should never happen)"

t_start "2.11 ccg_cleanup rejects basename with 'ccg.' in middle but not at start"
mkdir -p /tmp/foo-ccg.attack
result=$(ccg_cleanup "/tmp/foo-ccg.attack" 2>&1)
assert_match "$result" "skipped"
[ -d /tmp/foo-ccg.attack ] && rm -rf /tmp/foo-ccg.attack

# === 3. _ccg_redact ============================================================
t_start "3.1 redact sk- key"
result=$(echo "leaked: sk-1234567890abcdefghij_TAIL" | _ccg_redact)
assert_match "$result" "REDACTED"

t_start "3.2 redact AIza key"
result=$(echo "AIzaSyDXXXXXXXXXXXXXXXXXXXXXXXXXXX" | _ccg_redact)
assert_match "$result" "REDACTED"

t_start "3.3 redact Bearer token"
result=$(echo "Authorization: Bearer abcdef.xyz123" | _ccg_redact)
assert_match "$result" "Bearer "
assert_match "$result" "REDACTED"

t_start "3.4 redact URL query string"
result=$(echo "https://api.example.com/v1/foo?token=secret&id=42" | _ccg_redact)
assert_match "$result" "REDACTED"

t_start "3.5 redact GitHub PAT (ghp_)"
result=$(echo "ghp_ABCDEFGHIJ1234567890abcdef" | _ccg_redact)
assert_match "$result" "REDACTED"

t_start "3.6 redact JWT"
result=$(echo "eyJabcdefgh.payload.signaturehere" | _ccg_redact)
assert_match "$result" "REDACTED"

t_start "3.7 redact preserves non-secret content"
result=$(echo "normal log line about an error" | _ccg_redact)
assert_match "$result" "normal log line"
assert_nomatch "$result" "REDACTED"

# === 4. _ccg_run_with_timeout ==================================================
t_start "4.1 timeout returns 0 on quick success"
fresh_source
ec=0; _ccg_run_with_timeout 5 true || ec=$?
assert_eq "$ec" "0"

t_start "4.2 timeout returns non-zero on command failure"
fresh_source
ec=0; _ccg_run_with_timeout 5 false || ec=$?
assert_ne "$ec" "0"

t_start "4.3 timeout fires at 124 on hung command (sleep 10, timeout 2)"
fresh_source
start=$(date +%s)
ec=0; _ccg_run_with_timeout 2 sleep 10 || ec=$?
end=$(date +%s)
elapsed=$((end - start))
# ec=124 (timeout fired) + elapsed>=2 (didn't fire early) are the correctness
# signals. The upper bound only guards against "didn't kill at all" (which would
# run the full sleep 10) — kept comfortably under 10s but loose enough to absorb
# scheduling jitter under load (was 5s, which flaked when the suite ran hot).
if [ "$ec" -eq 124 ] && [ "$elapsed" -ge 2 ] && [ "$elapsed" -le 9 ]; then t_pass; else t_fail "ec=$ec elapsed=${elapsed}s"; fi

t_start "4.4 timeout preserves child's exit code on natural exit"
fresh_source
ec=0; _ccg_run_with_timeout 5 bash -c "exit 42" || ec=$?
assert_eq "$ec" "42"

t_start "4.5 timeout pure-bash fallback when 'timeout' is unavailable"
( PATH=/usr/bin:/bin; unset -f timeout gtimeout 2>/dev/null; \
  . "$HELPER"; \
  # remove the real one
  hide_dir=$(mktemp -d); \
  ln -sf /bin/false "$hide_dir/timeout"; ln -sf /bin/false "$hide_dir/gtimeout"; \
  PATH="$hide_dir:$PATH"; \
  if command -v timeout >/dev/null 2>&1; then PATH="${PATH#$hide_dir:}"; fi; \
  start=$(date +%s); ec=0; _ccg_run_with_timeout 2 sleep 10 || ec=$?; end=$(date +%s); \
  rm -rf "$hide_dir"; \
  if [ "$ec" -eq 124 ] && [ "$((end-start))" -le 9 ]; then exit 0; else echo "ec=$ec elapsed=$((end-start))"; exit 1; fi ) && t_pass || t_fail "pure-bash fallback timing"

# === 5. ccg_preflight ==========================================================
t_start "5.1 ccg_preflight reports missing codex if absent"
fresh_source
( PATH=/usr/bin:/bin; out=$(ccg_preflight 2>&1); \
  echo "$out" | grep -q "CCG_PREFLIGHT_CODEX=missing" && exit 0 || exit 1 ) && t_pass || t_fail "codex-missing not reported in stripped PATH"

t_start "5.2 ccg_preflight reports missing gemini if absent"
fresh_source
( PATH=/usr/bin:/bin; out=$(ccg_preflight 2>&1); \
  echo "$out" | grep -q "CCG_PREFLIGHT_GEMINI=missing" && exit 0 || exit 1 ) && t_pass || t_fail "gemini-missing not reported"

# === 6. ccg_codex via mocked binary ============================================
MOCK_DIR=$(mktemp -d)
trap 'rm -rf "$MOCK_DIR"' EXIT

# mock codex that simulates --output-last-message <FILE> by writing fixed text
cat > "$MOCK_DIR/codex" <<'MOCKEOF'
#!/usr/bin/env bash
out_file=""
prev=""
prompt_inline=""
for arg in "$@"; do
  case "$prev" in
    -o|--output-last-message) out_file="$arg" ;;
  esac
  prev="$arg"
done
# Drain stdin
prompt_stdin=$(cat || true)
# Behavior knob via env
case "${MOCK_CODEX_MODE:-ok}" in
  ok)        echo "codex synthesized answer about: ${prompt_stdin:0:40}" > "$out_file"; exit 0 ;;
  empty)    : > "$out_file"; exit 0 ;;
  fail)      echo "internal error" >&2; exit 1 ;;
  hang)      sleep 30; exit 0 ;;
  whitespace) printf '   \n  \n' > "$out_file"; exit 0 ;;
esac
exit 0
MOCKEOF
chmod +x "$MOCK_DIR/codex"

# mock gemini that writes stdout
cat > "$MOCK_DIR/gemini" <<'MOCKEOF'
#!/usr/bin/env bash
prompt=$(cat || true)
case "${MOCK_GEMINI_MODE:-ok}" in
  ok)         echo "gemini reply about: ${prompt:0:40}"; exit 0 ;;
  long_ok)    python3 -c 'print("A"*900 + " good answer")'; exit 0 ;;
  short_err)  echo '{"error":"unsupported model"}'; exit 0 ;;
  short_api_err) echo "API Error: rate limited"; exit 0 ;;
  long_err)   python3 -c 'print("API Error: " + "x"*900)'; exit 0 ;;  # >800 bytes — slips past
  empty)      : ; exit 0 ;;
  whitespace) printf '   \n   '; exit 0 ;;
  stderr_only) echo "real error" >&2; exit 1 ;;
  hang)        sleep 30; exit 0 ;;
  legit_with_error_word) echo "I reviewed your code; consider these error-handling improvements: 1) wrap try/catch around fs.read 2) propagate errors via Result type 3) avoid panic in production. Detailed analysis: $(printf 'D%.0s' {1..400})"; exit 0 ;;
esac
exit 0
MOCKEOF
chmod +x "$MOCK_DIR/gemini"

run_ccg_codex_with_mock() {
  local mode="$1"
  # $2 = timeout seconds. Default generous (30) so happy-path mocks never
  # spuriously time out under heavy load; hang tests pass a short value to fire
  # the timeout fast (the hang mock sleeps 30).
  local to="${2:-30}"
  fresh_source
  out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
  echo "review this file mode=$mode" > "$CCG_DIR/codex.prompt"
  ( PATH="$MOCK_DIR:$PATH" MOCK_CODEX_MODE="$mode" CCG_CODEX_TIMEOUT="$to" CCG_NO_CACHE=1 ccg_codex "$CCG_DIR/codex.prompt" "$CCG_DIR/codex.result" 2>&1 )
  ec=$?
  ccg_cleanup "$CCG_DIR" >/dev/null
  echo "EC=$ec"
}

run_ccg_gemini_with_mock() {
  local mode="$1"
  local to="${2:-30}"   # see run_ccg_codex_with_mock
  fresh_source
  out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
  echo "ux review mode=$mode" > "$CCG_DIR/gemini.prompt"
  ( PATH="$MOCK_DIR:$PATH" GEMINI_API_KEY="dummy-key" MOCK_GEMINI_MODE="$mode" CCG_GEMINI_TIMEOUT="$to" CCG_NO_CACHE=1 ccg_gemini "$CCG_DIR/gemini.prompt" "$CCG_DIR/gemini.result" 2>&1 )
  ec=$?
  ccg_cleanup "$CCG_DIR" >/dev/null
  echo "EC=$ec"
}

t_start "6.1 ccg_codex happy path returns CCG_CODEX_OK"
r=$(run_ccg_codex_with_mock ok)
assert_match "$r" "CCG_CODEX_OK"

t_start "6.2 ccg_codex empty output returns FAIL=empty-output"
r=$(run_ccg_codex_with_mock empty)
assert_match "$r" "CCG_CODEX_FAIL=empty-output"

t_start "6.3 ccg_codex whitespace-only output returns FAIL=whitespace-only-output"
r=$(run_ccg_codex_with_mock whitespace)
assert_match "$r" "CCG_CODEX_FAIL=whitespace-only-output"

t_start "6.4 ccg_codex CLI failure returns FAIL with empty output"
r=$(run_ccg_codex_with_mock fail)
assert_match "$r" "CCG_CODEX_FAIL=empty-output"

t_start "6.5 ccg_codex hung command times out at FAIL=timeout-Ns"
r=$(run_ccg_codex_with_mock hang 3)
assert_match "$r" "CCG_CODEX_FAIL=timeout"

t_start "6.6 ccg_codex with empty prompt returns FAIL=empty-prompt"
fresh_source; out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
: > "$CCG_DIR/codex.prompt"
r=$(PATH="$MOCK_DIR:$PATH" ccg_codex "$CCG_DIR/codex.prompt" "$CCG_DIR/codex.result" 2>&1)
ccg_cleanup "$CCG_DIR" >/dev/null
assert_match "$r" "CCG_CODEX_FAIL=empty-prompt"

t_start "6.7 ccg_codex with missing CLI returns FAIL=cli-missing"
fresh_source; out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
echo prompt > "$CCG_DIR/codex.prompt"
r=$(PATH=/usr/bin:/bin ccg_codex "$CCG_DIR/codex.prompt" "$CCG_DIR/codex.result" 2>&1)
ccg_cleanup "$CCG_DIR" >/dev/null
assert_match "$r" "CCG_CODEX_FAIL=cli-missing"

# === 7. ccg_gemini via mocked binary ===========================================
t_start "7.1 ccg_gemini happy path returns CCG_GEMINI_OK"
r=$(run_ccg_gemini_with_mock ok)
assert_match "$r" "CCG_GEMINI_OK"

t_start "7.2 ccg_gemini empty output returns FAIL=empty-output"
r=$(run_ccg_gemini_with_mock empty)
assert_match "$r" "CCG_GEMINI_FAIL=empty-output"

t_start "7.3 ccg_gemini whitespace-only returns FAIL=whitespace-only-output"
r=$(run_ccg_gemini_with_mock whitespace)
assert_match "$r" "CCG_GEMINI_FAIL=whitespace-only-output"

t_start "7.4 ccg_gemini short error blob (JSON) is flagged FAIL=error-leaked-to-stdout"
r=$(run_ccg_gemini_with_mock short_err)
assert_match "$r" "CCG_GEMINI_FAIL=error-leaked-to-stdout"

t_start "7.5 ccg_gemini short 'API Error:' blob is flagged FAIL=error-leaked-to-stdout"
r=$(run_ccg_gemini_with_mock short_api_err)
assert_match "$r" "CCG_GEMINI_FAIL=error-leaked-to-stdout"

t_start "7.6 ccg_gemini long legit content containing 'error' word is NOT flagged"
r=$(run_ccg_gemini_with_mock legit_with_error_word)
assert_match "$r" "CCG_GEMINI_OK"

t_start "7.7 ccg_gemini long error blob (>800b) is NOT flagged (known limitation, documented)"
r=$(run_ccg_gemini_with_mock long_err)
assert_match "$r" "CCG_GEMINI_OK"

t_start "7.8 ccg_gemini hung command times out at FAIL=timeout-Ns"
r=$(run_ccg_gemini_with_mock hang 3)
assert_match "$r" "CCG_GEMINI_FAIL=timeout"

t_start "7.9 ccg_gemini with empty prompt returns FAIL=empty-prompt"
fresh_source; out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
: > "$CCG_DIR/gemini.prompt"
r=$(PATH="$MOCK_DIR:$PATH" GEMINI_API_KEY=x ccg_gemini "$CCG_DIR/gemini.prompt" "$CCG_DIR/gemini.result" 2>&1)
ccg_cleanup "$CCG_DIR" >/dev/null
assert_match "$r" "CCG_GEMINI_FAIL=empty-prompt"

t_start "7.10 ccg_gemini missing CLI returns FAIL=cli-missing"
fresh_source; out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
echo p > "$CCG_DIR/gemini.prompt"
r=$(PATH=/usr/bin:/bin ccg_gemini "$CCG_DIR/gemini.prompt" "$CCG_DIR/gemini.result" 2>&1)
ccg_cleanup "$CCG_DIR" >/dev/null
assert_match "$r" "CCG_GEMINI_FAIL=cli-missing"

t_start "7.11 ccg_gemini missing API key (no launcher works) returns FAIL=no-api-key"
fresh_source; out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
echo p > "$CCG_DIR/gemini.prompt"
# Run in env that nukes GEMINI_API_KEY AND prevents launchers from finding it
r=$(env -i HOME=/nonexistent PATH="$MOCK_DIR:/usr/bin:/bin" CCG_SHELL_LAUNCHER=none bash -c "
  . '$HELPER'
  ccg_gemini '$CCG_DIR/gemini.prompt' '$CCG_DIR/gemini.result' 2>&1
")
ccg_cleanup "$CCG_DIR" >/dev/null
assert_match "$r" "CCG_GEMINI_FAIL=no-api-key"

# === 8. Dispatch guard =========================================================
t_start "8.1 dispatch via ./ccg.sh init creates a workdir"
out=$(bash "$HELPER" init 2>&1)
CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
if [ -n "$CCG_DIR" ] && [ -d "$CCG_DIR" ]; then t_pass; rm -rf "$CCG_DIR"; else t_fail "no CCG_DIR; out=$out"; fi

t_start "8.2 source with positional args MUST NOT dispatch (sourced-with-args footgun)"
result=$(bash -c "set -- init; . '$HELPER'; echo SOURCED_OK")
# expectation: only SOURCED_OK, no CCG_DIR= line
if echo "$result" | grep -q "SOURCED_OK" && ! echo "$result" | grep -q "^CCG_DIR="; then
  t_pass
else
  t_fail "leaked dispatch on source: $result"
fi

t_start "8.3 bash -c 'source ccg.sh' alone is silent (no dispatch)"
result=$(bash -c ". '$HELPER'; echo DONE")
if [ "$result" = "DONE" ]; then t_pass; else t_fail "unexpected: $result"; fi

t_start "8.4 unknown subcommand exits 2"
ec=0; bash "$HELPER" bogus 2>/dev/null || ec=$?
assert_eq "$ec" "2"

# === 9. Orphan sweep ===========================================================
t_start "9.1 orphan sweep removes >60 min old ccg.* dirs owned by current user"
fresh_source
# Create a fake "old" workdir via touch -t
fake="$TMPDIR/ccg.orphan_test_$$"
mkdir -p "$fake"
touch -t 200001010000 "$fake"
# trigger sweep
ccg_init >/dev/null
out_state="absent"
[ -d "$fake" ] && out_state="present"
[ -d "$fake" ] && rm -rf "$fake"
assert_eq "$out_state" "absent"

t_start "9.2 orphan sweep PRESERVES recent ccg.* dirs"
fresh_source
recent="$TMPDIR/ccg.recent_$$"
mkdir -p "$recent"
ccg_init >/dev/null
[ -d "$recent" ] && t_pass || t_fail "freshly-created dir was wiped"
rm -rf "$recent"

t_start "9.3 orphan sweep DOES NOT delete non-ccg dirs even when old"
fresh_source
nonccg="$TMPDIR/notccg_old_$$"
mkdir -p "$nonccg"
touch -t 200001010000 "$nonccg"
ccg_init >/dev/null
[ -d "$nonccg" ] && t_pass || t_fail "non-ccg dir was wiped"
rm -rf "$nonccg"

# === 10. Prompt-file edge cases ================================================
t_start "10.1 ccg_codex tolerates prompt with backticks/dollar signs/quotes"
fresh_source; out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
cat > "$CCG_DIR/codex.prompt" <<'EOF'
Review `expr 1+1` and $USER, plus "quotes" and 'single' and $(echo PWND).
EOF
r=$(PATH="$MOCK_DIR:$PATH" MOCK_CODEX_MODE=ok ccg_codex "$CCG_DIR/codex.prompt" "$CCG_DIR/codex.result" 2>&1)
assert_match "$r" "CCG_CODEX_OK"
# verify the file wasn't expanded
if grep -q 'PWND' "$CCG_DIR/codex.result"; then t_fail "shell expansion leaked"; fi
ccg_cleanup "$CCG_DIR" >/dev/null

t_start "10.2 ccg_codex result file is created even on early failure (no orphan reads)"
fresh_source; out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
# trigger empty-prompt branch
: > "$CCG_DIR/codex.prompt"
PATH="$MOCK_DIR:$PATH" ccg_codex "$CCG_DIR/codex.prompt" "$CCG_DIR/codex.result" >/dev/null 2>&1 || true
assert_file "$CCG_DIR/codex.result"
ccg_cleanup "$CCG_DIR" >/dev/null

# === 12. Mode resolution (silent), actual cost, usage log, cache, diff, size guard ===

t_start "12.1 _ccg_resolve_codex_model default is gpt-5.4 (balanced)"
fresh_source
out=$(_ccg_resolve_codex_model)
assert_eq "$out" "gpt-5.4"

t_start "12.2 _ccg_resolve_codex_model cost picks gpt-5-mini"
fresh_source
out=$(CCG_MODE=cost _ccg_resolve_codex_model)
assert_eq "$out" "gpt-5-mini"

t_start "12.2b _ccg_resolve_gemini_model cost picks gemini-2.5-flash-lite (not a qwen model)"
fresh_source
out=$(CCG_MODE=cost _ccg_resolve_gemini_model)
assert_eq "$out" "gemini-2.5-flash-lite"

t_start "12.3 _ccg_resolve_gemini_model quality picks gemini-3.5-flash"
fresh_source
out=$(CCG_MODE=quality _ccg_resolve_gemini_model)
assert_eq "$out" "gemini-3.5-flash"

t_start "12.4 CCG_CODEX_MODEL env wins over CCG_MODE"
fresh_source
out=$(CCG_MODE=cost CCG_CODEX_MODEL=o3-pro _ccg_resolve_codex_model)
assert_eq "$out" "o3-pro"

t_start "12.5 ccg_actual computes USD from byte counts"
fresh_source
tmpd=$(mktemp -d)
printf 'A%.0s' {1..600} > "$tmpd/p"
printf 'B%.0s' {1..1200} > "$tmpd/r"
out=$(ccg_actual "$tmpd/p" "$tmpd/r" gemini)
rm -rf "$tmpd"
assert_match "$out" "CCG_ACT_GEMINI_COST=USD="
assert_nomatch "$out" "CNY"

t_start "12.6 ccg_actual rejects missing files"
fresh_source
out=$(ccg_actual /nonexistent /nonexistent codex 2>&1)
assert_match "$out" "ACTUAL_FAIL"

t_start "12.7 ccg_actual unknown model produces zero cost"
fresh_source
tmpd=$(mktemp -d)
echo "x" > "$tmpd/p"; echo "y" > "$tmpd/r"
out=$(CCG_CODEX_MODEL=fake-model-xyz ccg_actual "$tmpd/p" "$tmpd/r" codex)
rm -rf "$tmpd"
assert_match "$out" "USD=0.0000"

t_start "12.8 dispatch supports actual subcommand"
tmpd=$(mktemp -d); echo a > "$tmpd/p"; echo b > "$tmpd/r"
out=$(bash "$HELPER" actual "$tmpd/p" "$tmpd/r" codex)
rm -rf "$tmpd"
assert_match "$out" "CCG_ACT_CODEX_COST"

t_start "12.9 ccg_usage on empty log returns no-data"
fresh_source
tmplog=$(mktemp); rm -f "$tmplog"
out=$(CCG_USAGE_LOG="$tmplog" ccg_usage --all)
assert_match "$out" "CCG_USAGE=no-data"

t_start "12.10 ccg_usage aggregates from log"
fresh_source
tmplog=$(mktemp)
printf '%s\tcodex\tgpt-5-mini\t100\t200\t0.000425\t0\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$tmplog"
printf '%s\tcodex\tgpt-5-mini\t150\t300\t0.000625\t0\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" >> "$tmplog"
printf '%s\tgemini\tgemini-2.5-flash\t100\t200\t0.0000675\t0\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" >> "$tmplog"
out=$(CCG_USAGE_LOG="$tmplog" ccg_usage --all)
rm -f "$tmplog"
assert_match "$out" "CCG_USAGE_TOTAL_CALLS=3"
assert_match "$out" "CCG_USAGE_CODEX_COST=USD=0.0010"
assert_match "$out" "CCG_USAGE_GEMINI_COST"
assert_match "$out" "CCG_USAGE_TOTAL_COST=USD=0.001"

t_start "12.11 ccg_usage counts cached calls separately"
fresh_source
tmplog=$(mktemp)
ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
printf '%s\tcodex\tgpt-5-mini\t100\t200\t0.0005\t0\n' "$ts" > "$tmplog"
printf '%s\tcodex\tgpt-5-mini\t100\t200\t0.000000\t1\n' "$ts" >> "$tmplog"
out=$(CCG_USAGE_LOG="$tmplog" ccg_usage --all)
rm -f "$tmplog"
assert_match "$out" "CCG_USAGE_TOTAL_CALLS=2"
assert_match "$out" "CCG_USAGE_CACHED_CALLS=1"

t_start "12.12 ccg_codex hits cache on second identical call"
fresh_source
tmpcache=$(mktemp -d)
tmplog=$(mktemp); rm -f "$tmplog"
out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
echo "stable prompt for cache test" > "$CCG_DIR/codex.prompt"
# First call → miss, populates cache
r1=$(CCG_CACHE_DIR="$tmpcache" CCG_USAGE_LOG="$tmplog" \
     PATH="$MOCK_DIR:$PATH" MOCK_CODEX_MODE=ok CCG_CODEX_TIMEOUT=30 \
     ccg_codex "$CCG_DIR/codex.prompt" "$CCG_DIR/codex.result" 2>&1)
# Second call → hit
r2=$(CCG_CACHE_DIR="$tmpcache" CCG_USAGE_LOG="$tmplog" \
     PATH="$MOCK_DIR:$PATH" MOCK_CODEX_MODE=ok CCG_CODEX_TIMEOUT=30 \
     ccg_codex "$CCG_DIR/codex.prompt" "$CCG_DIR/codex.result" 2>&1)
ccg_cleanup "$CCG_DIR" >/dev/null
rm -rf "$tmpcache" "$tmplog"
assert_match "$r2" "cache=hit"

t_start "12.13 CCG_NO_CACHE=1 bypasses cache"
fresh_source
tmpcache=$(mktemp -d)
out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
echo "stable" > "$CCG_DIR/codex.prompt"
CCG_CACHE_DIR="$tmpcache" PATH="$MOCK_DIR:$PATH" MOCK_CODEX_MODE=ok CCG_CODEX_TIMEOUT=30 \
  ccg_codex "$CCG_DIR/codex.prompt" "$CCG_DIR/codex.result" >/dev/null 2>&1
r=$(CCG_CACHE_DIR="$tmpcache" CCG_NO_CACHE=1 PATH="$MOCK_DIR:$PATH" MOCK_CODEX_MODE=ok CCG_CODEX_TIMEOUT=30 \
    ccg_codex "$CCG_DIR/codex.prompt" "$CCG_DIR/codex.result" 2>&1)
ccg_cleanup "$CCG_DIR" >/dev/null
rm -rf "$tmpcache"
assert_nomatch "$r" "cache=hit"

t_start "12.14 ccg_codex prompt > CCG_MAX_PROMPT_KB is rejected"
fresh_source
out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
# 10 KB prompt
yes "padding line for size guard test" 2>/dev/null | head -300 > "$CCG_DIR/codex.prompt"
r=$(CCG_MAX_PROMPT_KB=1 PATH="$MOCK_DIR:$PATH" ccg_codex "$CCG_DIR/codex.prompt" "$CCG_DIR/codex.result" 2>&1)
ccg_cleanup "$CCG_DIR" >/dev/null
assert_match "$r" "CCG_CODEX_FAIL=prompt-too-large"

t_start "12.15 ccg_diff_capture rejects non-git directory"
fresh_source
tmpd=$(mktemp -d)
( cd "$tmpd" && _ccg_run_with_timeout 5 bash -c 'cd '"$tmpd"' && exit' ) || true
r=$(cd "$tmpd" && ccg_diff_capture "$tmpd/d.txt" 2>&1)
rm -rf "$tmpd"
assert_match "$r" "CCG_DIFF_FAIL=not-a-git-repo"

t_start "12.16 ccg_diff_capture captures a real diff"
fresh_source
tmpd=$(mktemp -d)
( cd "$tmpd" \
  && git init -q . \
  && git config user.email t@t \
  && git config user.name t \
  && echo "v1" > f.txt && git add f.txt && git commit -q -m init \
  && echo "v2" > f.txt )
r=$(cd "$tmpd" && ccg_diff_capture "$tmpd/d.txt" 2>&1)
ok=0
if echo "$r" | grep -q "CCG_DIFF_OK" && grep -q "v2" "$tmpd/d.txt"; then ok=1; fi
rm -rf "$tmpd"
assert_eq "$ok" "1"

t_start "12.17 ccg_diff_capture empty-diff returns clean fail"
fresh_source
tmpd=$(mktemp -d)
( cd "$tmpd" \
  && git init -q . \
  && git config user.email t@t \
  && git config user.name t \
  && echo "v1" > f.txt && git add f.txt && git commit -q -m init )
r=$(cd "$tmpd" && ccg_diff_capture "$tmpd/d.txt" 2>&1)
rm -rf "$tmpd"
assert_match "$r" "CCG_DIFF_FAIL=empty-diff"

t_start "12.18 dispatch supports usage subcommand"
tmplog=$(mktemp); rm -f "$tmplog"
out=$(CCG_USAGE_LOG="$tmplog" bash "$HELPER" usage --all)
assert_match "$out" "CCG_USAGE="

t_start "12.19 dispatch supports diff_capture subcommand"
tmpd=$(mktemp -d)
( cd "$tmpd" && git init -q . && git config user.email t@t && git config user.name t \
  && echo x > a && git add a && git commit -q -m init && echo y > a )
out=$(cd "$tmpd" && bash "$HELPER" diff_capture "$tmpd/d.txt" 2>&1)
rm -rf "$tmpd"
assert_match "$out" "CCG_DIFF_OK"

t_start "12.20 ccg_codex passes -m model"
fresh_source; out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
echo "test" > "$CCG_DIR/codex.prompt"
cat > "$MOCK_DIR/codex" <<'EOF'
#!/usr/bin/env bash
echo "ARGS:$*" > /tmp/ccg_test_argsink.$$
out_file=""; prev=""
for arg in "$@"; do
  case "$prev" in -o|--output-last-message) out_file="$arg" ;; esac
  prev="$arg"
done
cat >/dev/null
echo "ok" > "$out_file"
EOF
chmod +x "$MOCK_DIR/codex"
rm -f /tmp/ccg_test_argsink.*
( PATH="$MOCK_DIR:$PATH" CCG_MODE=quality CCG_CODEX_TIMEOUT=30 CCG_NO_CACHE=1 \
  ccg_codex "$CCG_DIR/codex.prompt" "$CCG_DIR/codex.result" ) >/dev/null 2>&1
ccg_cleanup "$CCG_DIR" >/dev/null
saved=$(cat /tmp/ccg_test_argsink.* 2>/dev/null | head -1)
rm -f /tmp/ccg_test_argsink.*
assert_match "$saved" "-m gpt-5"
# restore default mock
cat > "$MOCK_DIR/codex" <<'EOF'
#!/usr/bin/env bash
out_file=""; prev=""
for arg in "$@"; do
  case "$prev" in -o|--output-last-message) out_file="$arg" ;; esac
  prev="$arg"
done
prompt_stdin=$(cat || true)
case "${MOCK_CODEX_MODE:-ok}" in
  ok)        echo "codex synthesized answer about: ${prompt_stdin:0:40}" > "$out_file"; exit 0 ;;
  empty)    : > "$out_file"; exit 0 ;;
  fail)      echo "internal error" >&2; exit 1 ;;
  hang)      sleep 30; exit 0 ;;
  whitespace) printf '   \n  \n' > "$out_file"; exit 0 ;;
esac
EOF
chmod +x "$MOCK_DIR/codex"


# === 13. v3 Pillar 1/2/3 ======================================================

# --- 13.A diff_capture upstream fallback ---
t_start "13.1 diff_capture finds upstream when worktree clean (committed not pushed)"
tmpd=$(mktemp -d); origin=$(mktemp -d)
( cd "$origin" && git init -q --bare . ) >/dev/null
( cd "$tmpd" && git init -q . && git config user.email t@t && git config user.name t \
  && git remote add origin "$origin" \
  && echo "v1" > a && git add a && git commit -q -m init && git push -q -u origin master \
  && echo "v2" > a && git add a && git commit -q -m update ) >/dev/null 2>&1
fresh_source
r=$(cd "$tmpd" && ccg_diff_capture "$tmpd/d.txt" 2>&1)
rm -rf "$tmpd" "$origin"
ok=0
if echo "$r" | grep -q "CCG_DIFF_OK" && echo "$r" | grep -q "CCG_DIFF_SOURCE=upstream:"; then ok=1; fi
assert_eq "$ok" "1"

t_start "13.2 diff_capture worktree wins over upstream when both present"
tmpd=$(mktemp -d); origin=$(mktemp -d)
( cd "$origin" && git init -q --bare . ) >/dev/null
( cd "$tmpd" && git init -q . && git config user.email t@t && git config user.name t \
  && git remote add origin "$origin" \
  && echo "v1" > a && git add a && git commit -q -m init && git push -q -u origin master \
  && echo "v2" > a && git add a && git commit -q -m update \
  && echo "v3-dirty" > a ) >/dev/null 2>&1
fresh_source
r=$(cd "$tmpd" && ccg_diff_capture "$tmpd/d.txt" 2>&1)
rm -rf "$tmpd" "$origin"
assert_match "$r" "CCG_DIFF_SOURCE=worktree"

# --- 13.B risk_score scenarios ---
t_start "13.3 risk_score auth path triggers high score"
tmpdiff=$(mktemp)
cat > "$tmpdiff" <<'EOF'
diff --git a/auth/login.go b/auth/login.go
index 1..2 100644
--- a/auth/login.go
+++ b/auth/login.go
@@ -1,2 +1,3 @@
 package auth
+func newCode() {}
EOF
fresh_source
r=$(ccg_risk_score "$tmpdiff" 2>&1)
rm -f "$tmpdiff"
assert_match "$r" "auth\+35"

t_start "13.4 risk_score docs-only subtracts and lands in cost mode"
tmpdiff=$(mktemp)
cat > "$tmpdiff" <<'EOF'
diff --git a/README.md b/README.md
index 1..2 100644
--- a/README.md
+++ b/README.md
@@ -1 +1,2 @@
 hello
+world
EOF
fresh_source
r=$(ccg_risk_score "$tmpdiff" 2>&1)
rm -f "$tmpdiff"
assert_match "$r" "CCG_RISK_MODE=cost"

t_start "13.5 risk_score sql-with-interp body signal triggers"
tmpdiff=$(mktemp)
cat > "$tmpdiff" <<'EOF'
diff --git a/db/query.py b/db/query.py
--- a/db/query.py
+++ b/db/query.py
@@ -1 +1,2 @@
+sql = f"SELECT * FROM users WHERE id={user_id}"
EOF
fresh_source
r=$(ccg_risk_score "$tmpdiff" 2>&1)
rm -f "$tmpdiff"
assert_match "$r" "sql_interp\+30"

t_start "13.6 risk_score size>600 + auth path picks quality"
tmpdiff=$(mktemp)
{
  echo "diff --git a/auth/big.go b/auth/big.go"
  echo "--- a/auth/big.go"
  echo "+++ b/auth/big.go"
  yes "+line of code added" 2>/dev/null | head -650
} > "$tmpdiff"
fresh_source
r=$(ccg_risk_score "$tmpdiff" 2>&1)
rm -f "$tmpdiff"
assert_match "$r" "CCG_RISK_MODE=quality"

t_start "13.7 risk_score on empty file fails cleanly"
tmpdiff=$(mktemp); : > "$tmpdiff"
fresh_source
r=$(ccg_risk_score "$tmpdiff" 2>&1)
rm -f "$tmpdiff"
assert_match "$r" "CCG_RISK_FAIL=empty-diff"

# --- 13.C ledger ---
t_start "13.8 ledger_record appends valid JSON"
fresh_source; out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
cat > "$CCG_DIR/diff.txt" <<'EOF'
diff --git a/x.go b/x.go
--- a/x.go
+++ b/x.go
@@ -1 +1,2 @@
 a
+b
EOF
ccg_risk_score "$CCG_DIR/diff.txt" > "$CCG_DIR/risk.txt"
echo "synth excerpt" > "$CCG_DIR/synthesis.txt"
LDG=$(mktemp); rm -f "$LDG"
CCG_LEDGER_LOG="$LDG" ccg_ledger_record "$CCG_DIR" >/dev/null
ok=0
if [ -s "$LDG" ] && python3 -c "import json,sys; json.loads(open('$LDG').read().strip())" 2>/dev/null; then
  ok=1
fi
rm -f "$LDG"; ccg_cleanup "$CCG_DIR" >/dev/null
assert_eq "$ok" "1"

t_start "13.9 ledger_record redacts secrets in synthesis"
fresh_source; out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
echo "diff --git a/a.go b/a.go" > "$CCG_DIR/diff.txt"
echo "+x" >> "$CCG_DIR/diff.txt"
ccg_risk_score "$CCG_DIR/diff.txt" > "$CCG_DIR/risk.txt"
printf 'token sk-abcdefghijklmnopqrstuvwxyz1234 leaked\n' > "$CCG_DIR/synthesis.txt"
LDG=$(mktemp); rm -f "$LDG"
CCG_LEDGER_LOG="$LDG" ccg_ledger_record "$CCG_DIR" >/dev/null
content=$(cat "$LDG")
rm -f "$LDG"; ccg_cleanup "$CCG_DIR" >/dev/null
assert_nomatch "$content" "sk-abcdefghijklmnopqrstuvwxyz"

t_start "13.10 ledger_query path filter works"
LDG=$(mktemp); rm -f "$LDG"
echo '{"ts":"x","paths":["src/auth.ts"]}' > "$LDG"
echo '{"ts":"y","paths":["src/util.ts"]}' >> "$LDG"
fresh_source
r=$(CCG_LEDGER_LOG="$LDG" ccg_ledger_query "auth" 2>&1)
rm -f "$LDG"
assert_match "$r" "CCG_LEDGER_MATCH=1"

t_start "13.11 ledger_query no-data on empty log"
LDG=$(mktemp); rm -f "$LDG"
fresh_source
r=$(CCG_LEDGER_LOG="$LDG" ccg_ledger_query 2>&1)
assert_match "$r" "CCG_LEDGER=no-data"

t_start "13.12 dispatch supports risk_score subcommand"
tmpdiff=$(mktemp)
cat > "$tmpdiff" <<'EOF'
diff --git a/foo b/foo
+x
EOF
out=$(bash "$HELPER" risk_score "$tmpdiff" 2>&1)
rm -f "$tmpdiff"
assert_match "$out" "CCG_RISK_SCORE="

t_start "13.13 dispatch supports ledger_query subcommand"
LDG=$(mktemp); rm -f "$LDG"
out=$(CCG_LEDGER_LOG="$LDG" bash "$HELPER" ledger_query 2>&1)
assert_match "$out" "CCG_LEDGER=no-data"

# === 14. ccg_persist_report ====================================================
# Persist a markdown report of the synthesis to <repo>/.ccg/reports/ so it
# survives the Claude Code session. See ccg.sh:ccg_persist_report.

# Helper: minimal workdir with synthesis.txt
_setup_persist_workdir() {
  local wd
  wd=$(mktemp -d -t ccg.test.XXXXXXXX)
  printf 'Test synthesis. DIVERGENCE on bcrypt: foo vs bar.\n' > "$wd/synthesis.txt"
  echo "$wd"
}

# Helper: transient git repo with one committed file (gives us a HEAD sha)
_setup_git_repo() {
  local repo
  repo=$(mktemp -d -t ccg.repo.XXXXXXXX)
  (
    cd "$repo"
    git init -q
    git config user.email "t@t"
    git config user.name "T"
    echo "x" > README.md
    git add README.md
    git commit -q -m "init"
  )
  echo "$repo"
}

t_start "14.1 persist_report writes report under <repo>/.ccg/reports/"
fresh_source
wd=$(_setup_persist_workdir); repo=$(_setup_git_repo)
out=$(cd "$repo" && ccg_persist_report "$wd" 2>&1)
report_path=$(echo "$out" | sed -n 's/^CCG_REPORT_OK=//p')
if [ -f "$report_path" ] && case "$report_path" in *.ccg/reports/*) true ;; *) false ;; esac
then t_pass
else t_fail "out=$out report=$report_path"; fi
rm -rf "$wd" "$repo"

t_start "14.2 persist_report respects CCG_NO_REPORT=1"
fresh_source
wd=$(_setup_persist_workdir)
out=$(CCG_NO_REPORT=1 ccg_persist_report "$wd" 2>&1)
assert_match "$out" "CCG_REPORT_SKIPPED=disabled"
rm -rf "$wd"

t_start "14.3 persist_report skips when synthesis.txt is missing"
fresh_source
wd=$(mktemp -d -t ccg.test.XXXXXXXX)
out=$(ccg_persist_report "$wd" 2>&1)
assert_match "$out" "CCG_REPORT_SKIPPED=no-synthesis"
rm -rf "$wd"

t_start "14.4 persist_report skips when not in git repo and no override"
fresh_source
wd=$(_setup_persist_workdir); nongit=$(mktemp -d)
out=$(cd "$nongit" && unset CCG_REPORT_DIR; ccg_persist_report "$wd" 2>&1)
assert_match "$out" "CCG_REPORT_SKIPPED=not-a-vcs-repo"
rm -rf "$wd" "$nongit"

t_start "14.5 persist_report uses CCG_REPORT_DIR override even outside git"
fresh_source
wd=$(_setup_persist_workdir); nongit=$(mktemp -d); odir=$(mktemp -d)
out=$(cd "$nongit" && CCG_REPORT_DIR="$odir" ccg_persist_report "$wd" 2>&1)
report_path=$(echo "$out" | sed -n 's/^CCG_REPORT_OK=//p')
if [ -f "$report_path" ] && case "$report_path" in "$odir"/*) true ;; *) false ;; esac
then t_pass
else t_fail "out=$out report=$report_path"; fi
rm -rf "$wd" "$nongit" "$odir"

t_start "14.6 persist_report redacts secrets in synthesis"
fresh_source
wd=$(mktemp -d -t ccg.test.XXXXXXXX)
printf 'leaked sk-abcdefghijklmnopqrstuvwxyz123456 in synth\n' > "$wd/synthesis.txt"
odir=$(mktemp -d)
out=$(CCG_REPORT_DIR="$odir" ccg_persist_report "$wd" 2>&1)
report_path=$(echo "$out" | sed -n 's/^CCG_REPORT_OK=//p')
content=$(cat "$report_path")
assert_nomatch "$content" "sk-abcdefghijklmnopqrstuvwxyz"
rm -rf "$wd" "$odir"

t_start "14.7 persist_report filename contains short-sha when repo has HEAD"
fresh_source
wd=$(_setup_persist_workdir); repo=$(_setup_git_repo)
expected_sha=$(cd "$repo" && git rev-parse --short HEAD)
out=$(cd "$repo" && ccg_persist_report "$wd" 2>&1)
report_path=$(echo "$out" | sed -n 's/^CCG_REPORT_OK=//p')
fname=$(basename "$report_path")
case "$fname" in
  "${expected_sha}"_*) t_pass ;;
  *) t_fail "expected ^${expected_sha}_  got $fname" ;;
esac
rm -rf "$wd" "$repo"

t_start "14.8 persist_report filename uses WIP outside git when forced via dir"
fresh_source
wd=$(_setup_persist_workdir); nongit=$(mktemp -d); odir=$(mktemp -d)
out=$(cd "$nongit" && CCG_REPORT_DIR="$odir" ccg_persist_report "$wd" 2>&1)
report_path=$(echo "$out" | sed -n 's/^CCG_REPORT_OK=//p')
fname=$(basename "$report_path")
case "$fname" in
  WIP_*) t_pass ;;
  *) t_fail "expected ^WIP_  got $fname" ;;
esac
rm -rf "$wd" "$nongit" "$odir"

t_start "14.9 persist_report embeds risk metadata in report header"
fresh_source
wd=$(_setup_persist_workdir)
printf 'CCG_RISK_SCORE=72\nCCG_RISK_MODE=quality\nCCG_RISK_REASONS=auth+35 size+5\n' > "$wd/risk.txt"
odir=$(mktemp -d)
out=$(CCG_REPORT_DIR="$odir" ccg_persist_report "$wd" 2>&1)
report_path=$(echo "$out" | sed -n 's/^CCG_REPORT_OK=//p')
content=$(cat "$report_path")
assert_match "$content" "Mode.*quality.*risk=72"
rm -rf "$wd" "$odir"

t_start "14.10 persist_report reads diff_source.txt sidecar"
fresh_source
wd=$(_setup_persist_workdir)
echo "upstream:origin/main" > "$wd/diff_source.txt"
odir=$(mktemp -d)
out=$(CCG_REPORT_DIR="$odir" ccg_persist_report "$wd" 2>&1)
report_path=$(echo "$out" | sed -n 's/^CCG_REPORT_OK=//p')
content=$(cat "$report_path")
assert_match "$content" "Diff source.*upstream:origin/main"
rm -rf "$wd" "$odir"

t_start "14.11 dispatch supports persist_report subcommand"
wd=$(_setup_persist_workdir); odir=$(mktemp -d)
out=$(CCG_REPORT_DIR="$odir" bash "$HELPER" persist_report "$wd" 2>&1)
assert_match "$out" "CCG_REPORT_OK="
rm -rf "$wd" "$odir"

t_start "14.12 diff_capture writes diff_source.txt sidecar"
fresh_source
repo=$(_setup_git_repo)
echo "modified" >> "$repo/README.md"
diff_out="$repo/.diff_out"
out=$(cd "$repo" && ccg_diff_capture "$diff_out" 2>&1)
sidecar="$(dirname "$diff_out")/diff_source.txt"
if [ -s "$sidecar" ] && grep -q "worktree" "$sidecar"; then
  t_pass
else
  t_fail "sidecar=$sidecar content=$(cat "$sidecar" 2>/dev/null) out=$out"
fi
rm -rf "$repo"


# === 15. ccg_ledger_context (write-only → bidirectional ledger) ================
# Verifies that prior reviews touching the same paths are surfaced into a
# history.txt that the protocol layer (ccg.md step 2.5) embeds into prompts.
# Without these tests, the L6 consumer path is silently broken under zsh,
# where `local var` inside a loop body leaks iteration N-1 values to stdout.

# Helper: build a workdir with diff.txt + a controlled ledger.
_setup_history_fixture() {
  local wd ledger
  wd=$(mktemp -d -t ccg.test.XXXXXXXX)
  cat > "$wd/diff.txt" <<EOF
diff --git a/auth/login.go b/auth/login.go
index 1234..5678 100644
--- a/auth/login.go
+++ b/auth/login.go
@@ -1,3 +1,4 @@
-old line
+new line
EOF
  ledger="$wd/ledger.jsonl"
  cat > "$ledger" <<EOF
{"ts":"2026-05-10T10:00:00Z","repo":"/r","branch":"x","sha":"abc1234","mode":"quality","risk":72,"files":1,"lines":"+5-0","paths":["auth/login.go"],"synthesis":"DIVERGENCE on constant-time compare."}
{"ts":"2026-05-15T11:00:00Z","repo":"/r","branch":"y","sha":"def5678","mode":"balanced","risk":40,"files":2,"lines":"+10-2","paths":["util/x.go"],"synthesis":"unrelated path."}
{"ts":"2026-05-20T12:00:00Z","repo":"/r","branch":"z","sha":"ghi9abc","mode":"quality","risk":80,"files":1,"lines":"+8-1","paths":["auth/login.go","auth/session.go"],"synthesis":"BLINDSPOT: error logging missing. fix-required."}
EOF
  echo "$wd"
}

t_start "15.1 ledger_context skipped when CCG_NO_HISTORY=1"
fresh_source
wd=$(_setup_history_fixture)
r=$(CCG_NO_HISTORY=1 CCG_LEDGER_LOG="$wd/ledger.jsonl" ccg_ledger_context "$wd/diff.txt" 2>&1)
rm -rf "$wd"
assert_match "$r" "CCG_HISTORY_SKIPPED=disabled"

t_start "15.2 ledger_context skipped when ledger missing"
fresh_source
wd=$(_setup_history_fixture)
r=$(CCG_LEDGER_LOG="$wd/no-such-ledger.jsonl" ccg_ledger_context "$wd/diff.txt" 2>&1)
rm -rf "$wd"
assert_match "$r" "CCG_HISTORY_SKIPPED=no-ledger"

t_start "15.3 ledger_context skipped when diff missing"
fresh_source
wd=$(_setup_history_fixture)
r=$(CCG_LEDGER_LOG="$wd/ledger.jsonl" ccg_ledger_context "$wd/no-such-diff.txt" 2>&1)
rm -rf "$wd"
assert_match "$r" "CCG_HISTORY_SKIPPED=no-diff"

t_start "15.4 ledger_context skipped when diff has no path headers"
fresh_source
wd=$(_setup_history_fixture)
echo "no diff headers, just text" > "$wd/diff.txt"
r=$(CCG_LEDGER_LOG="$wd/ledger.jsonl" ccg_ledger_context "$wd/diff.txt" 2>&1)
rm -rf "$wd"
assert_match "$r" "CCG_HISTORY_SKIPPED=no-paths-in-diff"

t_start "15.5 ledger_context returns NONE when no path overlap"
fresh_source
wd=$(_setup_history_fixture)
cat > "$wd/diff.txt" <<EOF
diff --git a/completely/different.txt b/completely/different.txt
+x
EOF
r=$(CCG_LEDGER_LOG="$wd/ledger.jsonl" ccg_ledger_context "$wd/diff.txt" 2>&1)
rm -rf "$wd"
assert_match "$r" "CCG_HISTORY_NONE=0_matches"

t_start "15.6 ledger_context writes history.txt on match"
fresh_source
wd=$(_setup_history_fixture)
r=$(CCG_LEDGER_LOG="$wd/ledger.jsonl" ccg_ledger_context "$wd/diff.txt" 2>&1)
hist_file="$wd/history.txt"
if [ -f "$hist_file" ] && grep -q "PRIOR REVIEWS" "$hist_file"; then t_pass
else t_fail "r=$r hist_exists=$([ -f "$hist_file" ] && echo yes || echo no)"; fi
rm -rf "$wd"

t_start "15.7 ledger_context history.txt contains ts/sha/mode for matched entries"
fresh_source
wd=$(_setup_history_fixture)
CCG_LEDGER_LOG="$wd/ledger.jsonl" ccg_ledger_context "$wd/diff.txt" >/dev/null 2>&1
content=$(cat "$wd/history.txt")
rm -rf "$wd"
# Must contain BOTH matching ledger entries (abc1234 and ghi9abc) but NOT the unrelated one
ok=1
echo "$content" | grep -q "abc1234" || ok=0
echo "$content" | grep -q "ghi9abc" || ok=0
echo "$content" | grep -q "def5678" && ok=0
assert_eq "$ok" "1"

t_start "15.8 ledger_context honors CCG_HISTORY_MAX=1"
fresh_source
wd=$(_setup_history_fixture)
CCG_HISTORY_MAX=1 CCG_LEDGER_LOG="$wd/ledger.jsonl" ccg_ledger_context "$wd/diff.txt" >/dev/null 2>&1
content=$(cat "$wd/history.txt")
rm -rf "$wd"
# Only the newest matching entry (ghi9abc) should be present.
echo "$content" | grep -q "ghi9abc" && ! echo "$content" | grep -q "abc1234" \
  && t_pass || t_fail "content=$content"

t_start "15.9 ledger_context history.txt contains NO bash/zsh debug-leak lines"
# Regression guard: zsh's `local var` (no =) inside a loop body prints iteration N-1
# values. This test would FAIL if a future contributor refactors local declarations
# back inside the loop. We assert that lines like 'ts=...' or 'sha=...' (raw KV
# without the proper '- [..] sha=...' framing) do not appear at line start.
fresh_source
wd=$(_setup_history_fixture)
CCG_LEDGER_LOG="$wd/ledger.jsonl" ccg_ledger_context "$wd/diff.txt" >/dev/null 2>&1
hist=$(cat "$wd/history.txt")
rm -rf "$wd"
# Each rendered entry starts with "- [TIMESTAMP]". A leaked debug line would
# start with a bare "ts=" or "synth='".  Reject either pattern at column 1.
if printf '%s\n' "$hist" | grep -qE '^(ts|sha|mode|lines_field|paths_list|synth)=' ; then
  t_fail "found bare KEY= line in history.txt (zsh local-leak regression)"
else
  t_pass
fi

t_start "15.10 ledger_context dispatch subcommand works"
wd=$(_setup_history_fixture)
out=$(CCG_LEDGER_LOG="$wd/ledger.jsonl" bash "$HELPER" ledger_context "$wd/diff.txt" 2>&1)
rm -rf "$wd"
assert_match "$out" "CCG_HISTORY_(OK|NONE|SKIPPED)"


# === 11. Real CLI smoke test (opt-in) ==========================================
if [ "${REAL_CLI:-0}" = "1" ]; then
  t_start "11.1 real Codex E2E (fast prompt)"
  fresh_source; out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
  echo "Say the literal word READY and nothing else." > "$CCG_DIR/codex.prompt"
  r=$(ccg_codex "$CCG_DIR/codex.prompt" "$CCG_DIR/codex.result" 2>&1)
  ans=$(cat "$CCG_DIR/codex.result")
  ccg_cleanup "$CCG_DIR" >/dev/null
  if echo "$r" | grep -q "CCG_CODEX_OK" && echo "$ans" | grep -qi "READY"; then t_pass; else t_fail "r=$r ans=$ans"; fi

  if command -v gemini >/dev/null; then
    t_start "11.2 real Gemini E2E (fast prompt)"
    fresh_source; out=$(ccg_init); CCG_DIR=$(echo "$out" | sed -n 's/^CCG_DIR=//p')
    echo "Say the literal word PONG and nothing else." > "$CCG_DIR/gemini.prompt"
    # Real Gemini may be unreachable on the runner — that's fine as long as ccg
    # reports a clean failure reason (graceful degradation path).
    r=$(CCG_GEMINI_TIMEOUT=60 ccg_gemini "$CCG_DIR/gemini.prompt" "$CCG_DIR/gemini.result" 2>&1)
    ans=$(cat "$CCG_DIR/gemini.result")
    ccg_cleanup "$CCG_DIR" >/dev/null
    if echo "$r" | grep -q "CCG_GEMINI_OK" && echo "$ans" | grep -qi "PONG"; then
      t_pass
    elif echo "$r" | grep -qE "CCG_GEMINI_FAIL=(timeout|error-leaked|empty-output|no-api-key)"; then
      # Clean failure reason → /ccg's graceful degradation path is exercised.
      t_pass
      echo "    (real Gemini unreachable — graceful degradation verified: $(echo "$r" | head -1))" >&2
    else
      t_fail "r=$r ans=$ans"
    fi
  fi
fi

# === Summary ===================================================================
END_TS=$(date +%s)
echo
echo "================================================================"
printf '  Tests: %d passed, %d failed   (%ds total)\n' "$PASS" "$FAIL" "$((END_TS - START_TS))"
if [ "$FAIL" -gt 0 ]; then
  echo "  Failed tests:"
  for n in "${FAIL_NAMES[@]}"; do echo "    - $n"; done
  exit 1
fi
echo "================================================================"
exit 0
