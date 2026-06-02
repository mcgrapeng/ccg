#!/usr/bin/env bash
# tests/test_ccg_routing.sh — coverage for the v4 model-routing redesign:
#   - Stage 1 default = two DIFFERENT-vendor Bailian models
#   - codex/gemini/claude are quality-only
#   - minimax registry + pricing
#   - vendor utility + different-vendor enforcement
#   - mode-aware synthesizer selection
#   - risk scoring is deterministic by default (LLM is opt-in)
#   - ledger records non-empty metadata when given the workdir (regression for
#     the $(pwd) bug)
#
# No real API calls — keys are unset and the vendor checks fire before launch.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORKFLOW="$ROOT/ccg-workflow.sh"
[ -r "$WORKFLOW" ] || { echo "FATAL: $WORKFLOW not found" >&2; exit 2; }

PASS=0; FAIL=0
_pass() { printf 'PASS %s\n' "$1"; PASS=$((PASS+1)); }
_fail() { printf 'FAIL %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
_eq() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "expected '$3' got '$2'"; fi; }
_contains() { if printf '%s' "$2" | grep -q -- "$3"; then _pass "$1"; else _fail "$1" "missing '$3' in: $2"; fi; }

# Isolate XDG + caches so we never touch the user's real data.
TEST_HOME=$(mktemp -d)
export CCG_CACHE_DIR="$TEST_HOME/cache"
export CCG_USAGE_LOG="$TEST_HOME/usage.log"
export CCG_LEDGER_LOG="$TEST_HOME/ledger.jsonl"
export CCG_NO_REPORT=1 CCG_NO_HISTORY=1 CCG_NO_CACHE=1
trap 'rm -rf "$TEST_HOME"' EXIT

# Source everything (workflow pulls in ccg.sh + bailian-models + multi-provider).
unset BAILIAN_API_KEY GEMINI_API_KEY ANTHROPIC_API_KEY CLAUDE_API_KEY CCG_PROVIDERS CCG_MODE 2>/dev/null || true
# shellcheck source=/dev/null
. "$WORKFLOW"

# ── minimax registry + pricing ───────────────────────────────────────
out=$(_ccg_bailian_models | grep -c '^minimax-')
_eq "minimax: 2 models registered" "$out" "2"
_eq "minimax-m2 input price"  "$(_ccg_price minimax-m2 input)"        "0.30"
_eq "minimax-m2 output price" "$(_ccg_price minimax-m2 output)"       "0.90"
_eq "minimax-m2-lite price"   "$(_ccg_price minimax-m2-lite input)"   "0.15"
_eq "minimax exists()"        "$(_ccg_bailian_model_exists minimax-m2 && echo yes || echo no)" "yes"

# ── pricing: -lite/-plus arms must NOT be swallowed by the general arm ───
_eq "price deepseek-v4-lite (not 0.35)" "$(_ccg_price deepseek-v4-lite input)" "0.18"
_eq "price kimi-k2.6-lite (not 0.32)"   "$(_ccg_price kimi-k2.6-lite input)"   "0.16"
_eq "price glm-5.1-lite (not 0.28)"     "$(_ccg_price glm-5.1-lite input)"     "0.14"
_eq "price qwen-3.6-plus (not 0.25)"    "$(_ccg_price qwen-3.6-plus input)"    "0.20"
_eq "price deepseek-v4 (general intact)" "$(_ccg_price deepseek-v4 input)"     "0.35"

# ── resolver dedup: ccg_actual-facing resolvers are CCG_MODE-based (ccg.sh) ──
_eq "resolve codex by CCG_MODE=quality" "$(CCG_MODE=quality _ccg_resolve_codex_model)" "gpt-5.5"
_eq "resolve gemini by CCG_MODE=cost"   "$(CCG_MODE=cost _ccg_resolve_gemini_model)"   "gemini-2.5-flash-lite"

# ── redaction: secrets the V1 audit found leaking must now be masked ──
_redacts() { if printf '%s' "$2" | _ccg_redact | grep -q 'REDACTED' && ! printf '%s' "$2" | _ccg_redact | grep -qF "$3"; then _pass "redact: $1"; else _fail "redact: $1" "leaked: $(printf '%s' "$2" | _ccg_redact)"; fi; }
_redacts "AWS_SECRET_ACCESS_KEY" "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIbPxRfiCYEXAMPLEKEY" "wJalrXUtnFEMIbPxRfiCYEXAMPLEKEY"
_redacts "generic *_KEY env"     "MY_API_KEY=abcdef0123456789xyz"                       "abcdef0123456789xyz"
_redacts "PASSWORD"              "PASSWORD=Hunter2Hunter2Hunter2"                        "Hunter2Hunter2Hunter2"
_redacts "DB_PASS"               "DB_PASS=SuperSecretValue123"                           "SuperSecretValue123"
_redacts "stripe sk_live_"       "STRIPE=sk_live_REDACTED"                        "REDACTED"
_redacts "url userinfo"          "postgres://user:SuperSecretDbPass@host/db"            "SuperSecretDbPass"
_redacts "lowercase token= (8+)" "token=abc123secret456"                                "abc123secret456"

# ── numeric guard: bad CCG_*_TEMP/MAX_TOKENS falls back, never blanks jq ──
_eq "num_or valid decimal"   "$(_ccg_num_or 0.7 0.5)"   "0.7"
_eq "num_or valid int"       "$(_ccg_num_or 4096 1)"    "4096"
_eq "num_or non-numeric→def" "$(_ccg_num_or abc 0.7)"   "0.7"
_eq "num_or empty→def"       "$(_ccg_num_or '' 4096)"   "4096"
_eq "num_or multi-dot→def"   "$(_ccg_num_or 1.2.3 0.7)" "0.7"

# ── vendor utility ───────────────────────────────────────────────────
_eq "vendor qwen"     "$(_ccg_vendor_of qwen-3.6)"      "qwen"
_eq "vendor deepseek" "$(_ccg_vendor_of deepseek-v4)"   "deepseek"
_eq "vendor minimax"  "$(_ccg_vendor_of minimax-m2)"    "minimax"
_eq "vendor mimo (not minimax)" "$(_ccg_vendor_of mimo-v2.5)" "mimo"
_eq "vendor glm"      "$(_ccg_vendor_of glm-5.1)"       "glm"
_eq "vendor kimi"     "$(_ccg_vendor_of kimi-k2.6)"     "kimi"
_eq "vendor openai"   "$(_ccg_vendor_of gpt-5.5)"       "openai"
_eq "vendor google"   "$(_ccg_vendor_of gemini-3.5-flash)" "google"
_eq "vendor anthropic" "$(_ccg_vendor_of claude-opus-4-7)" "anthropic"

# ── default-pair is two different vendors ────────────────────────────
pair=$(_ccg_resolve_bailian_pair balanced)
pa=$(printf '%s\n' "$pair" | sed -n '1p'); pb=$(printf '%s\n' "$pair" | sed -n '2p')
va=$(_ccg_vendor_of "$pa"); vb=$(_ccg_vendor_of "$pb")
if [ "$va" != "$vb" ]; then _pass "bailian pair is different vendors ($va vs $vb)"; else _fail "bailian pair vendors" "both $va"; fi

# ── mode-aware default providers ─────────────────────────────────────
_eq "default providers quality"  "$(_ccg_default_providers quality)" "codex gemini"
_contains "default providers balanced uses qwen"     "$(_ccg_default_providers balanced)" "bailian:qwen"
_contains "default providers balanced uses deepseek" "$(_ccg_default_providers balanced)" "bailian:deepseek"

# ── premium classification ───────────────────────────────────────────
for p in codex gemini claude; do
  if _ccg_is_premium_provider "$p"; then _pass "premium: $p"; else _fail "premium: $p" "not flagged"; fi
done
if _ccg_is_premium_provider bailian; then _fail "bailian not premium" "wrongly flagged"; else _pass "bailian is not premium"; fi

# ── synthesizer selection ────────────────────────────────────────────
_eq "synth non-quality = bailian"          "$(_ccg_pick_synth balanced bailian bailian)" "bailian"
_eq "synth quality codex+gemini -> claude" "$(_ccg_pick_synth quality codex gemini)"     "claude"
_eq "synth quality claude+codex -> gemini" "$(_ccg_pick_synth quality claude codex)"     "gemini"
_eq "synth quality claude+gemini -> codex" "$(_ccg_pick_synth quality claude gemini)"    "codex"

# ── risk scoring is deterministic even when BAILIAN_API_KEY is set ───
t_risk_deterministic() {
  local d; d=$(mktemp)
  printf 'diff --git a/src/util.js b/src/util.js\n--- a/src/util.js\n+++ b/src/util.js\n@@\n+const x = 1\n' > "$d"
  local out
  out=$(BAILIAN_API_KEY=fake-key ccg_risk_score "$d" 2>/dev/null)
  rm -f "$d"
  if printf '%s' "$out" | grep -q '^CCG_RISK_SCORE='; then
    _pass "risk-score deterministic without CCG_RISK_LLM (no LLM call)"
  else
    _fail "risk-score deterministic" "no CCG_RISK_SCORE line: $out"
  fi
}
t_risk_deterministic

# ── ledger records non-empty metadata from the workdir (regression) ──
t_ledger_nonempty() {
  local wd; wd=$(mktemp -d)
  printf 'diff --git a/src/auth.ts b/src/auth.ts\n--- a/src/auth.ts\n+++ b/src/auth.ts\n@@\n+login()\n' > "$wd/diff.txt"
  printf 'CCG_RISK_SCORE=42\nCCG_RISK_MODE=balanced\n' > "$wd/risk.txt"
  printf 'CLASSIFICATION: AGREEMENT\nVERDICT: merge\n' > "$wd/synthesis.txt"
  local ldg="$TEST_HOME/ledger_unit.jsonl"
  CCG_LEDGER_LOG="$ldg" ccg_ledger_record "$wd" >/dev/null 2>&1
  local line; line=$(tail -1 "$ldg" 2>/dev/null)
  rm -rf "$wd"
  if printf '%s' "$line" | grep -q '"files":1' \
     && printf '%s' "$line" | grep -q '"paths":\["src/auth.ts"\]'; then
    _pass "ledger records non-empty files/paths (regression for \$(pwd) bug)"
  else
    _fail "ledger non-empty" "line=$line"
  fi
}
t_ledger_nonempty

# ── integration: ccg_review enforces different vendors + quality gate ─
_new_repo_with_change() {
  local g; g=$(mktemp -d)
  git -C "$g" init -q -b main
  git -C "$g" config user.email t@t; git -C "$g" config user.name t
  echo base > "$g/base.txt"; git -C "$g" add -A; git -C "$g" commit -q -m init
  printf 'change\n' >> "$g/base.txt"
  printf '%s' "$g"
}

t_same_vendor_blocked() {
  local g; g=$(_new_repo_with_change)
  local out ec=0
  out=$(
    cd "$g"
    unset BAILIAN_API_KEY GEMINI_API_KEY ANTHROPIC_API_KEY CLAUDE_API_KEY
    export CCG_MODE=balanced CCG_PROVIDERS="bailian:qwen-3.6 bailian:qwen-3.7"
    . "$WORKFLOW"
    ccg_review 2>&1
  ) || ec=$?
  rm -rf "$g"
  if [ "$ec" = "2" ] && printf '%s' "$out" | grep -q 'DIFFERENT-vendor'; then
    _pass "ccg_review blocks same-vendor Stage 1 pair"
  else
    _fail "same-vendor blocked" "ec=$ec out=$out"
  fi
}
t_same_vendor_blocked

t_same_vendor_override() {
  local g; g=$(_new_repo_with_change)
  local out ec=0
  out=$(
    cd "$g"
    unset BAILIAN_API_KEY GEMINI_API_KEY ANTHROPIC_API_KEY CLAUDE_API_KEY
    export CCG_MODE=balanced CCG_PROVIDERS="bailian:qwen-3.6 bailian:qwen-3.7" CCG_ALLOW_SAME_VENDOR=1
    . "$WORKFLOW"
    ccg_review 2>&1
  ) || ec=$?
  rm -rf "$g"
  # With the override the vendor guard is bypassed; both slots then fail to
  # validate (no BAILIAN_API_KEY), so we should NOT see the vendor error.
  if printf '%s' "$out" | grep -q 'DIFFERENT-vendor'; then
    _fail "same-vendor override" "guard still fired: $out"
  else
    _pass "CCG_ALLOW_SAME_VENDOR=1 bypasses vendor guard"
  fi
}
t_same_vendor_override

t_premium_gated_outside_quality() {
  local g; g=$(_new_repo_with_change)
  local out ec=0
  out=$(
    cd "$g"
    unset BAILIAN_API_KEY GEMINI_API_KEY ANTHROPIC_API_KEY CLAUDE_API_KEY
    export CCG_MODE=balanced CCG_PROVIDERS="codex gemini"
    . "$WORKFLOW"
    ccg_review 2>&1
  ) || ec=$?
  rm -rf "$g"
  if printf '%s' "$out" | grep -q 'quality-only'; then
    _pass "codex/gemini skipped outside quality mode"
  else
    _fail "premium gated" "ec=$ec out=$out"
  fi
}
t_premium_gated_outside_quality

# ── integration: ccg_precommit_gate routes by mode (Bailian in non-quality) ──
t_gate_uses_bailian_non_quality() {
  # Provide mock codex/gemini that WOULD emit merge if (wrongly) used. In
  # balanced mode the gate must use Bailian instead; with no BAILIAN_API_KEY it
  # fails closed and the diagnostic mentions BAILIAN — proving the mocks weren't used.
  local tmpbin; tmpbin=$(mktemp -d)
  cat > "$tmpbin/codex" <<'EOF'
#!/usr/bin/env bash
out=""; prev=""; for a in "$@"; do [ "$prev" = "--output-last-message" ] && out="$a"; prev="$a"; done
prompt=$(cat); s=$(printf '%s' "$prompt" | grep -oE '<<<CCG_VERDICT_[A-F0-9]+:' | head -1)
[ -n "$out" ] && printf '%smerge>>>\n' "$s" > "$out"
EOF
  chmod +x "$tmpbin/codex"
  cat > "$tmpbin/gemini" <<'EOF'
#!/usr/bin/env bash
prompt=$(cat); s=$(printf '%s' "$prompt" | grep -oE '<<<CCG_VERDICT_[A-F0-9]+:' | head -1)
printf '%smerge>>>\n' "$s"
EOF
  chmod +x "$tmpbin/gemini"
  local g; g=$(_new_repo_with_change)
  local out ec=0
  out=$(
    cd "$g"
    export PATH="$tmpbin:$PATH" GEMINI_API_KEY=mock CCG_NO_CACHE=1 CCG_NO_REPORT=1 CCG_NO_HISTORY=1 CCG_MODE=balanced
    unset BAILIAN_API_KEY ANTHROPIC_API_KEY CLAUDE_API_KEY
    . "$WORKFLOW"
    ccg_precommit_gate 2>&1
  ) || ec=$?
  rm -rf "$tmpbin" "$g"
  if [ "$ec" = "1" ] && printf '%s' "$out" | grep -qi 'BAILIAN'; then
    _pass "gate uses Bailian (not codex/gemini) in non-quality mode"
  else
    _fail "gate non-quality bailian" "ec=$ec out=$out"
  fi
}
t_gate_uses_bailian_non_quality

t_gate_quality_uses_premium() {
  # Mock codex+gemini emit merge; in quality mode the gate must use them → exit 0.
  local tmpbin; tmpbin=$(mktemp -d)
  cat > "$tmpbin/codex" <<'EOF'
#!/usr/bin/env bash
out=""; prev=""; for a in "$@"; do [ "$prev" = "--output-last-message" ] && out="$a"; prev="$a"; done
prompt=$(cat); s=$(printf '%s' "$prompt" | grep -oE '<<<CCG_VERDICT_[A-F0-9]+:' | head -1)
[ -n "$out" ] && printf '%smerge>>>\n' "$s" > "$out"
EOF
  chmod +x "$tmpbin/codex"
  cat > "$tmpbin/gemini" <<'EOF'
#!/usr/bin/env bash
prompt=$(cat); s=$(printf '%s' "$prompt" | grep -oE '<<<CCG_VERDICT_[A-F0-9]+:' | head -1)
printf '%smerge>>>\n' "$s"
EOF
  chmod +x "$tmpbin/gemini"
  local g; g=$(_new_repo_with_change)
  local ec=0
  (
    cd "$g"
    export PATH="$tmpbin:$PATH" GEMINI_API_KEY=mock CCG_NO_CACHE=1 CCG_NO_REPORT=1 CCG_NO_HISTORY=1 CCG_MODE=quality
    unset BAILIAN_API_KEY ANTHROPIC_API_KEY CLAUDE_API_KEY
    . "$WORKFLOW"
    ccg_precommit_gate 2>/dev/null
  ) || ec=$?
  rm -rf "$tmpbin" "$g"
  if [ "$ec" = "0" ]; then
    _pass "gate uses codex+gemini in quality mode (verdict merge → exit 0)"
  else
    _fail "gate quality premium" "expected ec=0 got ec=$ec"
  fi
}
t_gate_quality_uses_premium

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
