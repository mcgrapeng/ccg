#!/usr/bin/env bash
# ccg.sh v3 — Helper functions for /ccg slash command.
# Sourced by Claude when executing the /ccg protocol.
# Pure bash (3.2+), POSIX awk/sed/find/git. Safe under set -u.
#
# v3 identity: divergence detector, not consensus reporter.
#   - Pillar 1: synthesizer outputs AGREEMENT / DIVERGENCE / BLINDSPOT
#   - Pillar 2: ccg_risk_score → auto-pick cost|balanced|quality
#   - Pillar 3: ccg_ledger_record → append-only review history
#
# Public API:
#   ccg_init                          → echo CCG_DIR=... CCG_*_PROMPT=... etc.
#   ccg_preflight                     → echo CCG_PREFLIGHT_{CODEX,GEMINI}={ok|...}
#   ccg_diff_capture <out_file>       → 4-level fallback; emits CCG_DIFF_SOURCE
#   ccg_risk_score <diff_file>        → deterministic 0..100+ score → suggested mode
#   ccg_codex <prompt> <out>          → call codex; honors cache; logs usage
#   ccg_gemini <prompt> <out>         → call gemini; honors cache; logs usage
#   ccg_actual <prompt_f> <result_f> <provider> → echo USD actual cost
#   ccg_usage [--this-month|--all]    → summarize $XDG_DATA_HOME/ccg/usage.log
#   ccg_ledger_record <workdir>       → append JSONL row to $XDG_DATA_HOME/ccg/ledger.jsonl
#   ccg_ledger_query [path-substring] → find prior reviews touching path
#   ccg_cleanup <dir>                 → rm -rf the workdir (skipped if CCG_KEEP_ARTIFACTS=1)
#
# Configuration via environment variables:
#   CCG_MODE            — cost | balanced | quality (default: balanced)
#                         (empty/auto + risk score available → auto-pick)
#   CCG_CODEX_MODEL     — Override codex model (wins over CCG_MODE)
#   CCG_GEMINI_MODEL    — Override gemini model (wins over CCG_MODE)
#   CCG_CODEX_TIMEOUT   — Codex hard timeout seconds (default: 240)
#   CCG_GEMINI_TIMEOUT  — Gemini hard timeout seconds (default: 120)
#   CCG_KEEP_ARTIFACTS  — Set to 1 to keep workdir for debugging
#   CCG_NO_CACHE        — Set to 1 to bypass prompt-hash cache
#   CCG_CACHE_TTL_HOURS — Cache TTL in hours (default: 24)
#   CCG_CACHE_DIR       — Cache directory (default: $XDG_CACHE_HOME/ccg/cache)
#   CCG_MAX_PROMPT_KB   — Reject prompts larger than this (default: 100)
#   CCG_USAGE_LOG       — Override usage log path (default: $XDG_DATA_HOME/ccg/usage.log)
#   CCG_LEDGER_LOG      — Override ledger path (default: $XDG_DATA_HOME/ccg/ledger.jsonl)
#
# Storage paths follow XDG Base Directory Specification:
#   * Cache:   $XDG_CACHE_HOME/ccg          (fallback: ~/.cache/ccg)
#   * Data:    $XDG_DATA_HOME/ccg           (fallback: ~/.local/share/ccg)
#   * Config:  $XDG_CONFIG_HOME/ccg         (fallback: ~/.config/ccg)
# Legacy ~/.ccg/* is auto-migrated on first run; deletion is non-destructive.
#
# Pricing snapshot: 2026-05 (USD per 1M tokens, official API rates).
# Update _ccg_price() to refresh.

# ============================================================
# Internal: XDG path resolution + one-time legacy migration
# ============================================================
_ccg_xdg_data_dir()   { printf '%s/ccg\n' "${XDG_DATA_HOME:-$HOME/.local/share}"; }
_ccg_xdg_cache_dir()  { printf '%s/ccg\n' "${XDG_CACHE_HOME:-$HOME/.cache}"; }
_ccg_xdg_config_dir() { printf '%s/ccg\n' "${XDG_CONFIG_HOME:-$HOME/.config}"; }

# Migrate ~/.ccg/* to XDG locations on first encounter.
# Idempotent: only moves if source exists AND destination does NOT.
_ccg_migrate_legacy() {
  local legacy="$HOME/.ccg"
  [ -d "$legacy" ] || return 0

  local data_dir cache_dir
  data_dir=$(_ccg_xdg_data_dir)
  cache_dir=$(_ccg_xdg_cache_dir)
  mkdir -p "$data_dir" "$cache_dir"

  [ -f "$legacy/usage.log" ]   && [ ! -e "$data_dir/usage.log" ]   && mv "$legacy/usage.log"   "$data_dir/usage.log"   2>/dev/null
  [ -f "$legacy/ledger.jsonl" ] && [ ! -e "$data_dir/ledger.jsonl" ] && mv "$legacy/ledger.jsonl" "$data_dir/ledger.jsonl" 2>/dev/null
  [ -d "$legacy/cache" ]       && [ ! -e "$cache_dir/cache" ]      && mv "$legacy/cache"       "$cache_dir/cache"      2>/dev/null

  # Drop empty legacy dir, keep non-empty for user inspection
  rmdir "$legacy" 2>/dev/null || true
}
_ccg_migrate_legacy

# ============================================================
# Internal: portable timeout (sub-second polling, wall-clock deadline)
# ============================================================
_ccg_run_with_timeout() {
  local seconds="$1"; shift
  local start_ts ec=0
  start_ts=$(date +%s)

  if command -v timeout >/dev/null 2>&1; then
    timeout "${seconds}s" "$@" || ec=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${seconds}s" "$@" || ec=$?
  else
    # CRITICAL: explicit `<&0` preserves stdin into backgrounded child.
    # Bash auto-redirects async stdin to /dev/null when job control is off.
    "$@" <&0 &
    local pid=$!
    local now elapsed_sec timed_out=0
    local sleep_unit
    if sleep 0.1 2>/dev/null; then sleep_unit=0.1; else sleep_unit=1; fi
    while kill -0 "$pid" 2>/dev/null; do
      now=$(date +%s)
      elapsed_sec=$((now - start_ts))
      if [ "$elapsed_sec" -ge "$seconds" ]; then
        timed_out=1
        kill -TERM "$pid" 2>/dev/null || true
        sleep "$sleep_unit" 2>/dev/null || true
        kill -KILL "$pid" 2>/dev/null || true
        break
      fi
      sleep "$sleep_unit" 2>/dev/null || break
    done
    if wait "$pid" 2>/dev/null; then ec=0; else ec=$?; fi
    if [ "$timed_out" = "1" ]; then return 124; fi
    if [ "$ec" -eq 127 ]; then ec=0; fi
    return "$ec"
  fi

  local end_ts elapsed
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))
  if [ "$ec" -eq 124 ]; then return 124; fi
  if [ "$ec" -eq 137 ] || [ "$ec" -eq 143 ]; then
    if [ "$elapsed" -ge $((seconds - 2)) ]; then return 124; fi
  fi
  return "$ec"
}

# ============================================================
# Internal: redact secrets
# ============================================================
_ccg_redact() {
  LC_ALL=C sed -E \
    -e 's/(sk-[A-Za-z0-9_-]{1,12})[A-Za-z0-9_-]{8,}/\1***REDACTED***/g' \
    -e 's/(AIza[A-Za-z0-9_-]{0,6})[A-Za-z0-9_-]{15,}/\1***REDACTED***/g' \
    -e 's/(gh[opsu]_)[A-Za-z0-9]+/\1***REDACTED***/g' \
    -e 's/(xox[abporst]-)[A-Za-z0-9-]+/\1***REDACTED***/g' \
    -e 's/(AKIA[A-Z0-9]{4})[A-Z0-9]+/\1***REDACTED***/g' \
    -e 's/(eyJ[A-Za-z0-9_-]{8})[A-Za-z0-9._\/+=-]+/\1***REDACTED***/g' \
    -e 's/(Bearer +)[A-Za-z0-9._\/+=-]+/\1***REDACTED***/g' \
    -e 's#(https?://[^/[:space:]]+/[^?[:space:]]*)\?[^[:space:]]+#\1?***REDACTED***#g'
}

# ============================================================
# Internal: shell launcher detection (for Gemini API key resolution)
# ============================================================
_ccg_pick_launcher() {
  local need_var="$1"
  if [ -n "$(printenv "$need_var" 2>/dev/null)" ]; then echo ""; return 0; fi
  if command -v zsh >/dev/null 2>&1 && \
     zsh -i -c "printenv $need_var" 2>/dev/null | grep -q .; then
    echo "zsh -i -c "; return 0
  fi
  if command -v bash >/dev/null 2>&1 && \
     bash -i -c "printenv $need_var" 2>/dev/null | grep -q .; then
    echo "bash -i -c "; return 0
  fi
  echo ""; return 1
}

# ============================================================
# Internal: pricing table (USD per 1M tokens, as of 2026-05)
# ============================================================
_ccg_price() {
  local model="$1" field="${2:-input}"
  local in_price out_price
  case "$model" in
    gpt-5|gpt-5-2025-*)              in_price=1.25;   out_price=10.00 ;;
    gpt-5-mini|gpt-5-mini-*)         in_price=0.25;   out_price=2.00 ;;
    gpt-5-nano|gpt-5-nano-*)         in_price=0.05;   out_price=0.40 ;;
    gpt-4.1)                         in_price=2.00;   out_price=8.00 ;;
    gpt-4.1-mini)                    in_price=0.40;   out_price=1.60 ;;
    gpt-4o)                          in_price=2.50;   out_price=10.00 ;;
    gpt-4o-mini)                     in_price=0.15;   out_price=0.60 ;;
    o3|o3-*)                         in_price=2.00;   out_price=8.00 ;;
    o4-mini|o4-mini-*)               in_price=1.10;   out_price=4.40 ;;
    gemini-2.5-pro|gemini-2.5-pro-*) in_price=1.25;   out_price=10.00 ;;
    gemini-2.5-flash|gemini-2.5-flash-2025-*) in_price=0.075; out_price=0.30 ;;
    gemini-2.5-flash-lite|gemini-2.5-flash-lite-*) in_price=0.05; out_price=0.20 ;;
    gemini-1.5-pro|gemini-1.5-pro-*) in_price=1.25;   out_price=5.00 ;;
    gemini-1.5-flash|gemini-1.5-flash-*) in_price=0.075; out_price=0.30 ;;
    *)                               in_price=0;      out_price=0 ;;
  esac
  case "$field" in
    input)  echo "$in_price" ;;
    output) echo "$out_price" ;;
    *)      echo "0" ;;
  esac
}

_ccg_tokens_from_chars() {
  awk -v c="$1" 'BEGIN { r=3.0; printf "%d", (c + r - 1) / r }'
}

# ============================================================
# Internal: mode → model resolution (silent)
# ============================================================
_ccg_resolve_codex_model() {
  if [ -n "${CCG_CODEX_MODEL:-}" ]; then echo "$CCG_CODEX_MODEL"; return; fi
  case "${CCG_MODE:-balanced}" in
    cost)    echo "gpt-5-nano" ;;
    quality) echo "gpt-5" ;;
    *)       echo "gpt-5-mini" ;;
  esac
}
_ccg_resolve_gemini_model() {
  if [ -n "${CCG_GEMINI_MODEL:-}" ]; then echo "$CCG_GEMINI_MODEL"; return; fi
  case "${CCG_MODE:-balanced}" in
    cost)    echo "gemini-2.5-flash-lite" ;;
    quality) echo "gemini-2.5-pro" ;;
    *)       echo "gemini-2.5-flash" ;;
  esac
}

# ============================================================
# Internal: cache key + path
# ============================================================
_ccg_cache_dir() {
  local d="${CCG_CACHE_DIR:-$(_ccg_xdg_cache_dir)/cache}"
  mkdir -p "$d" 2>/dev/null
  echo "$d"
}

_ccg_cache_key() {
  local prompt_file="$1" model="$2"
  local hasher
  if command -v shasum >/dev/null 2>&1; then hasher="shasum -a 256"
  elif command -v sha256sum >/dev/null 2>&1; then hasher="sha256sum"
  else echo ""; return 1; fi
  ( printf 'model=%s\n' "$model"; cat "$prompt_file" ) | $hasher | awk '{print $1}'
}

_ccg_cache_lookup() {
  if [ "${CCG_NO_CACHE:-0}" = "1" ]; then return 1; fi
  local key="$1" cache_dir
  cache_dir=$(_ccg_cache_dir) || return 1
  local cache_file="$cache_dir/$key"
  [ -s "$cache_file" ] || return 1
  local ttl_hours="${CCG_CACHE_TTL_HOURS:-24}"
  local ttl_min=$((ttl_hours * 60))
  if find -L "$cache_file" -mmin +"$ttl_min" 2>/dev/null | grep -q .; then
    return 1
  fi
  echo "$cache_file"
  return 0
}

_ccg_cache_store() {
  local key="$1" result_file="$2" cache_dir
  cache_dir=$(_ccg_cache_dir) || return 1
  cp "$result_file" "$cache_dir/$key" 2>/dev/null || true
}

# ============================================================
# Internal: usage log
# ============================================================
_ccg_log_usage() {
  local provider="$1" model="$2" in_tokens="$3" out_tokens="$4" usd="$5" cached="$6"
  local log="${CCG_USAGE_LOG:-$(_ccg_xdg_data_dir)/usage.log}"
  mkdir -p "$(dirname "$log")" 2>/dev/null
  local ts
  ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$provider" "$model" "$in_tokens" "$out_tokens" "$usd" "$cached" \
    >> "$log"
}

# ============================================================
# Public: ccg_actual <prompt_file> <result_file> <provider>
# ============================================================
ccg_actual() {
  local prompt_file="$1" result_file="$2" provider="$3"
  if [ ! -f "$prompt_file" ] || [ ! -f "$result_file" ]; then
    echo "CCG_ACTUAL_FAIL=missing-file"
    return 2
  fi
  local in_chars out_chars in_tokens out_tokens model
  in_chars=$(wc -c <"$prompt_file" | tr -d ' ')
  out_chars=$(wc -c <"$result_file" | tr -d ' ')
  in_tokens=$(_ccg_tokens_from_chars "$in_chars")
  out_tokens=$(_ccg_tokens_from_chars "$out_chars")
  case "$provider" in
    codex)  model=$(_ccg_resolve_codex_model) ;;
    gemini) model=$(_ccg_resolve_gemini_model) ;;
    *)      echo "CCG_ACTUAL_FAIL=unknown-provider"; return 2 ;;
  esac
  local in_price out_price usd
  in_price=$(_ccg_price "$model" input)
  out_price=$(_ccg_price "$model" output)
  usd=$(awk -v ip="$in_price" -v op="$out_price" -v it="$in_tokens" -v ot="$out_tokens" \
        'BEGIN { printf "%.6f", (ip * it + op * ot) / 1000000 }')
  local upper
  upper=$(echo "$provider" | tr '[:lower:]' '[:upper:]')
  printf 'CCG_ACT_%s_MODEL=%s\n' "$upper" "$model"
  printf 'CCG_ACT_%s_TOKENS=in=%s,out=%s\n' "$upper" "$in_tokens" "$out_tokens"
  printf 'CCG_ACT_%s_COST=USD=%.4f\n' "$upper" "$usd"
}

# ============================================================
# Public: ccg_usage [--this-month|--all]
# ============================================================
ccg_usage() {
  local mode="${1:---this-month}"
  local log="${CCG_USAGE_LOG:-$(_ccg_xdg_data_dir)/usage.log}"
  if [ ! -s "$log" ]; then
    echo "CCG_USAGE=no-data (log: $log)"
    return 0
  fi
  local cutoff=""
  case "$mode" in
    --this-month) cutoff=$(date -u +'%Y-%m') ;;
    --all|"")     cutoff="" ;;
    --since=*)    cutoff="${mode#--since=}" ;;
    *) echo "CCG_USAGE_FAIL=unknown-flag: $mode"; return 2 ;;
  esac
  awk -v cutoff="$cutoff" '
    BEGIN { OFS="\t" }
    cutoff != "" && index($1, cutoff) != 1 { next }
    {
      total_calls++
      cost[$2] += $6
      tokens_in[$2] += $4
      tokens_out[$2] += $5
      if ($7 == "1") cached_calls++
    }
    END {
      printf "CCG_USAGE_RANGE=%s\n", (cutoff == "" ? "all-time" : cutoff)
      printf "CCG_USAGE_TOTAL_CALLS=%d\n", total_calls
      printf "CCG_USAGE_CACHED_CALLS=%d\n", cached_calls + 0
      total_usd = 0
      for (p in cost) {
        printf "CCG_USAGE_%s_COST=USD=%.4f tokens=in=%d,out=%d\n", \
          toupper(p), cost[p], tokens_in[p], tokens_out[p]
        total_usd += cost[p]
      }
      printf "CCG_USAGE_TOTAL_COST=USD=%.4f\n", total_usd
    }
  ' "$log"
}

# ============================================================
# Public: ccg_diff_capture <out_file>
# Fallback chain: worktree → staged → upstream(branch) → origin-head
# Emits CCG_DIFF_SOURCE so callers know what scope was captured.
# ============================================================
ccg_diff_capture() {
  local out_file="$1"
  if ! command -v git >/dev/null 2>&1; then
    echo "CCG_DIFF_FAIL=git-missing"; return 127
  fi
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "CCG_DIFF_FAIL=not-a-git-repo"; return 2
  fi

  local diff_text="" source=""

  diff_text=$(git diff HEAD 2>/dev/null)
  [ -n "$diff_text" ] && source="worktree"

  if [ -z "$diff_text" ]; then
    diff_text=$(git diff --cached 2>/dev/null)
    [ -n "$diff_text" ] && source="staged"
  fi

  if [ -z "$diff_text" ]; then
    local upstream
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
    if [ -n "$upstream" ] && [ "$upstream" != "@{u}" ]; then
      diff_text=$(git diff "${upstream}...HEAD" 2>/dev/null)
      [ -n "$diff_text" ] && source="upstream:${upstream}"
    fi
  fi

  if [ -z "$diff_text" ]; then
    if git rev-parse --verify --quiet origin/HEAD >/dev/null 2>&1; then
      diff_text=$(git diff "origin/HEAD...HEAD" 2>/dev/null)
      [ -n "$diff_text" ] && source="origin-head"
    fi
  fi

  if [ -z "$diff_text" ]; then
    echo "CCG_DIFF_FAIL=empty-diff"; return 1
  fi

  printf '%s\n' "$diff_text" > "$out_file"
  # Sidecar: persist the source label so later steps (e.g. ccg_persist_report)
  # can read it across Bash invocations where env vars don't carry over.
  local sidecar
  sidecar="$(dirname "$out_file")/diff_source.txt"
  printf '%s\n' "$source" > "$sidecar" 2>/dev/null || :
  local sz
  sz=$(wc -c <"$out_file" | tr -d ' ')
  echo "CCG_DIFF_OK=${sz}b"
  echo "CCG_DIFF_SOURCE=${source}"
}

# ============================================================
# Public: ccg_risk_score <diff_file>
# Deterministic risk scoring → suggested mode (cost|balanced|quality).
# Pure rules, no LLM. Output is parseable KEY=VAL lines.
# Score scale: 0..100+. Thresholds: <20 cost, <60 balanced, else quality.
# ============================================================
ccg_risk_score() {
  local diff_file="$1"
  if [ ! -s "$diff_file" ]; then
    echo "CCG_RISK_FAIL=empty-diff"; return 2
  fi

  local score=0 reasons=""
  local files_changed lines_added lines_removed total_changed

  files_changed=$(grep -cE '^diff --git ' "$diff_file" 2>/dev/null | head -1)
  lines_added=$(grep -cE '^\+[^+]' "$diff_file" 2>/dev/null | head -1)
  lines_removed=$(grep -cE '^-[^-]' "$diff_file" 2>/dev/null | head -1)
  : "${files_changed:=0}"; : "${lines_added:=0}"; : "${lines_removed:=0}"
  total_changed=$((lines_added + lines_removed))

  # File path signals (high-risk areas)
  local path_block
  path_block=$(grep -E '^diff --git ' "$diff_file" 2>/dev/null || true)

  _risk_path_match() {
    local pat="$1" weight="$2" label="$3"
    if printf '%s\n' "$path_block" | grep -qiE -- "$pat"; then
      score=$((score + weight))
      reasons="${reasons}${reasons:+ }${label}+${weight}"
    fi
  }

  _risk_path_match '/(auth|authn|authz|login|session|oauth|jwt|token)' 35 "auth"
  _risk_path_match '/(payment|billing|invoice|stripe|checkout|charge)' 40 "payment"
  _risk_path_match '/(migration|migrate|schema)' 30 "migration"
  _risk_path_match '/(crypto|encrypt|decrypt|hash|secret)' 30 "crypto"
  _risk_path_match '/(security|permission|acl|rbac)' 25 "security"
  _risk_path_match '/(infra|terraform|kubernetes|k8s|helm|deploy)' 20 "infra"
  _risk_path_match '/(\.github/workflows|ci|pipeline)' 15 "ci"

  # Low-risk path signals (subtract)
  if printf '%s\n' "$path_block" \
     | grep -qE '\.(md|txt|rst|adoc)$|/docs?/|/CHANGELOG'; then
    if ! printf '%s\n' "$path_block" | grep -qvE '\.(md|txt|rst|adoc)$|/docs?/|/CHANGELOG'; then
      score=$((score - 40))
      reasons="${reasons}${reasons:+ }docs_only-40"
    fi
  fi

  # Content signals (operate on the diff body, +lines only)
  local added_body
  added_body=$(grep -E '^\+[^+]' "$diff_file" 2>/dev/null || true)

  _risk_body_match() {
    local pat="$1" weight="$2" label="$3"
    if printf '%s' "$added_body" | grep -qiE -- "$pat"; then
      score=$((score + weight))
      reasons="${reasons}${reasons:+ }${label}+${weight}"
    fi
  }

  _risk_body_match '\b(exec|eval|system|popen|shell_exec|child_process|spawn[^a-z])' 25 "shell_exec"
  _risk_body_match '\b(SELECT|INSERT|UPDATE|DELETE|DROP|ALTER)\b.*(\$\{?[a-zA-Z_]|\{[a-zA-Z_])' 30 "sql_interp"
  _risk_body_match '\b(rm -rf|unlink|removeSync|fs\.rm|os\.remove)' 20 "fs_delete"
  _risk_body_match '\b(setuid|setgid|chmod 7|chown)' 25 "privilege"
  _risk_body_match '\b(localhost|0\.0\.0\.0|127\.0\.0\.1):[0-9]' 5 "hardcoded_host"
  _risk_body_match '\b(TODO|FIXME|XXX|HACK)\b' 5 "todo_marker"

  # Size signal
  if [ "$total_changed" -gt 600 ]; then
    score=$((score + 25)); reasons="${reasons}${reasons:+ }size>600+25"
  elif [ "$total_changed" -gt 300 ]; then
    score=$((score + 15)); reasons="${reasons}${reasons:+ }size>300+15"
  elif [ "$total_changed" -gt 100 ]; then
    score=$((score + 5)); reasons="${reasons}${reasons:+ }size>100+5"
  fi

  # Multi-file blast radius
  if [ "$files_changed" -gt 8 ]; then
    score=$((score + 10)); reasons="${reasons}${reasons:+ }files>8+10"
  fi

  # Floor
  [ "$score" -lt 0 ] && score=0

  local mode
  if   [ "$score" -lt 20 ]; then mode="cost"
  elif [ "$score" -lt 60 ]; then mode="balanced"
  else                           mode="quality"
  fi

  printf 'CCG_RISK_SCORE=%d\n' "$score"
  printf 'CCG_RISK_MODE=%s\n'  "$mode"
  printf 'CCG_RISK_FILES=%d\n' "$files_changed"
  printf 'CCG_RISK_LINES=+%d-%d\n' "$lines_added" "$lines_removed"
  printf 'CCG_RISK_REASONS=%s\n' "${reasons:-none}"
}

# ============================================================
# Public: ccg_ledger_record <workdir>
# Append a JSONL record of this review to the ledger.
# Reads CCG_DIR/diff.txt + CCG_DIR/synthesis.txt + risk score.
# ============================================================
ccg_ledger_record() {
  local workdir="$1"
  local ledger="${CCG_LEDGER_LOG:-$(_ccg_xdg_data_dir)/ledger.jsonl}"
  mkdir -p "$(dirname "$ledger")" 2>/dev/null

  local diff_file="$workdir/diff.txt"
  local synth_file="$workdir/synthesis.txt"
  local risk_file="$workdir/risk.txt"

  local ts repo branch sha files lines mode score
  ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    repo=$(git rev-parse --show-toplevel 2>/dev/null)
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    sha=$(git rev-parse --short HEAD 2>/dev/null)
  else
    repo=""; branch=""; sha=""
  fi

  if [ -s "$risk_file" ]; then
    mode=$(grep '^CCG_RISK_MODE=' "$risk_file" | head -1 | cut -d= -f2)
    score=$(grep '^CCG_RISK_SCORE=' "$risk_file" | head -1 | cut -d= -f2)
  else
    mode=""; score=""
  fi

  if [ -s "$diff_file" ]; then
    files=$(grep -cE '^diff --git ' "$diff_file" 2>/dev/null | head -1)
    local added removed
    added=$(grep -cE '^\+[^+]' "$diff_file" 2>/dev/null | head -1)
    removed=$(grep -cE '^-[^-]' "$diff_file" 2>/dev/null | head -1)
    : "${files:=0}"; : "${added:=0}"; : "${removed:=0}"
    lines="+${added}-${removed}"
  else
    files=0; lines="+0-0"
  fi

  # Files touched (path list, deduped)
  local paths_json="[]"
  if [ -s "$diff_file" ]; then
    paths_json=$(awk '
      /^diff --git a\// {
        sub(/^diff --git a\//, "")
        sub(/ b\/.*$/, "")
        if (!seen[$0]++) paths[++n] = $0
      }
      END {
        printf "["
        for (i = 1; i <= n; i++) {
          if (i > 1) printf ","
          gsub(/\\/, "\\\\", paths[i])
          gsub(/"/, "\\\"", paths[i])
          printf "\"%s\"", paths[i]
        }
        printf "]"
      }
    ' "$diff_file")
  fi

  # Synthesis summary (first 400 chars, JSON-escaped)
  local synth_excerpt=""
  if [ -s "$synth_file" ]; then
    synth_excerpt=$(LC_ALL=C head -c 400 "$synth_file" \
      | _ccg_redact \
      | awk 'BEGIN { ORS = "" }
             { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, ""); gsub(/\n/, "\\n"); print }')
  fi

  printf '{"ts":"%s","repo":"%s","branch":"%s","sha":"%s","mode":"%s","risk":%s,"files":%d,"lines":"%s","paths":%s,"synthesis":"%s"}\n' \
    "$ts" "$repo" "$branch" "$sha" "$mode" "${score:-null}" \
    "$files" "$lines" "$paths_json" "$synth_excerpt" \
    >> "$ledger"

  echo "CCG_LEDGER_OK=appended"
  echo "CCG_LEDGER_PATH=$ledger"
}

# ============================================================
# Public: ccg_ledger_query [path-substring]
# Find prior reviews touching a given path (or all if omitted).
# ============================================================
ccg_ledger_query() {
  local needle="${1:-}"
  local ledger="${CCG_LEDGER_LOG:-$(_ccg_xdg_data_dir)/ledger.jsonl}"
  if [ ! -s "$ledger" ]; then
    echo "CCG_LEDGER=no-data (log: $ledger)"
    return 0
  fi
  if [ -z "$needle" ]; then
    local n
    n=$(wc -l <"$ledger" | tr -d ' ')
    echo "CCG_LEDGER_TOTAL=$n"
    tail -5 "$ledger"
    return 0
  fi
  local matches
  matches=$(grep -F -- "$needle" "$ledger" 2>/dev/null | tail -10)
  if [ -z "$matches" ]; then
    echo "CCG_LEDGER_MATCH=0 needle=$needle"
    return 0
  fi
  local count
  count=$(printf '%s\n' "$matches" | wc -l | tr -d ' ')
  echo "CCG_LEDGER_MATCH=$count needle=$needle"
  printf '%s\n' "$matches"
}

# ============================================================
# Public: ccg_persist_report <workdir>
#
# Materializes a single self-contained Markdown report of the review under
# <repo_root>/.ccg/reports/<sha-or-WIP>_<UTC-timestamp>.md, so the synthesis,
# raw Codex output, and raw Gemini output survive Claude Code session closure.
#
# Inputs (from workdir):
#   - synthesis.txt   (required — full Claude synthesis; ledger truncates separately)
#   - diff.txt        (optional — used for file/line counts)
#   - diff_source.txt (optional — written by ccg_diff_capture)
#   - risk.txt        (optional — used for mode/score/reasons)
#   - codex.result    (optional — appended as raw block)
#   - gemini.result   (optional — appended as raw block)
#
# Environment overrides:
#   CCG_NO_REPORT=1      → skip persistence entirely
#   CCG_REPORT_DIR=<dir> → write to this dir instead of <repo>/.ccg/reports/
#
# Outputs:
#   CCG_REPORT_OK=<path>     on success
#   CCG_REPORT_SKIPPED=<why> when intentionally skipped (no-synthesis / disabled / not-a-git-repo)
#   CCG_REPORT_FAIL=<why>    on filesystem error
# ============================================================
ccg_persist_report() {
  local workdir="$1"

  if [ "${CCG_NO_REPORT:-0}" = "1" ]; then
    echo "CCG_REPORT_SKIPPED=disabled"
    return 0
  fi

  local synth_file="$workdir/synthesis.txt"
  if [ ! -s "$synth_file" ]; then
    echo "CCG_REPORT_SKIPPED=no-synthesis"
    return 0
  fi

  # Resolve target directory.
  local out_dir
  if [ -n "${CCG_REPORT_DIR:-}" ]; then
    out_dir="$CCG_REPORT_DIR"
  elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    out_dir="$(git rev-parse --show-toplevel 2>/dev/null)/.ccg/reports"
  else
    echo "CCG_REPORT_SKIPPED=not-a-git-repo"
    return 0
  fi

  if ! mkdir -p "$out_dir" 2>/dev/null; then
    echo "CCG_REPORT_FAIL=cannot-create-dir:$out_dir"
    return 1
  fi

  # Compose filename: <sha-or-WIP>_<YYYYMMDD>-<HHMMSS>.md
  local ts_iso ts_fname sha branch repo
  ts_iso=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  ts_fname=$(date -u +'%Y%m%d-%H%M%S')

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    repo=$(git rev-parse --show-toplevel 2>/dev/null)
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    sha=$(git rev-parse --short HEAD 2>/dev/null || echo "WIP")
  else
    repo=""; branch=""; sha="WIP"
  fi

  local report_path="$out_dir/${sha:-WIP}_${ts_fname}.md"

  # Gather optional metadata.
  local mode score reasons source_label
  local diff_file="$workdir/diff.txt"
  local risk_file="$workdir/risk.txt"
  local source_file="$workdir/diff_source.txt"
  local codex_result="$workdir/codex.result"
  local gemini_result="$workdir/gemini.result"

  if [ -s "$risk_file" ]; then
    mode=$(grep '^CCG_RISK_MODE=' "$risk_file" | head -1 | cut -d= -f2)
    score=$(grep '^CCG_RISK_SCORE=' "$risk_file" | head -1 | cut -d= -f2)
    reasons=$(grep '^CCG_RISK_REASONS=' "$risk_file" | head -1 | cut -d= -f2-)
  fi

  if [ -s "$source_file" ]; then
    source_label=$(head -1 "$source_file" | tr -d '\r\n')
  else
    source_label="${CCG_DIFF_SOURCE:-unknown}"
  fi

  local files_count=0 added=0 removed=0
  if [ -s "$diff_file" ]; then
    files_count=$(grep -cE '^diff --git ' "$diff_file" 2>/dev/null | head -1)
    added=$(grep -cE '^\+[^+]' "$diff_file" 2>/dev/null | head -1)
    removed=$(grep -cE '^-[^-]' "$diff_file" 2>/dev/null | head -1)
    : "${files_count:=0}"; : "${added:=0}"; : "${removed:=0}"
  fi

  # Write report. Redact every section that came from outside (LLM output / diff).
  {
    printf '# ccg report\n\n'
    printf -- '- **Generated**: %s\n' "$ts_iso"
    [ -n "$repo" ] && printf -- '- **Repo**: %s\n' "$repo"
    [ -n "$branch" ] && printf -- '- **Branch**: %s\n' "$branch"
    printf -- '- **SHA**: %s\n' "$sha"
    printf -- '- **Diff source**: %s\n' "$source_label"
    printf -- '- **Files**: %s (+%s -%s)\n' "$files_count" "$added" "$removed"
    if [ -n "$mode" ]; then
      printf -- '- **Mode**: %s' "$mode"
      [ -n "$score" ] && printf ' (risk=%s' "$score"
      [ -n "$reasons" ] && printf ', reasons=%s' "$reasons"
      [ -n "$score" ] && printf ')'
      printf '\n'
    fi

    printf '\n---\n\n## Synthesis (Claude)\n\n'
    _ccg_redact < "$synth_file"

    printf '\n\n---\n\n## Codex (raw)\n\n'
    if [ -s "$codex_result" ]; then
      printf '```\n'
      _ccg_redact < "$codex_result"
      printf '\n```\n'
    else
      printf '_(no codex output)_\n'
    fi

    printf '\n---\n\n## Gemini (raw)\n\n'
    if [ -s "$gemini_result" ]; then
      printf '```\n'
      _ccg_redact < "$gemini_result"
      printf '\n```\n'
    else
      printf '_(no gemini output)_\n'
    fi

    printf '\n---\n\n*Generated by ccg. Re-render this evaluation by running `/ccg` in Claude Code.*\n'
  } > "$report_path" 2>/dev/null || {
    echo "CCG_REPORT_FAIL=write-failed:$report_path"
    return 1
  }

  echo "CCG_REPORT_OK=$report_path"
}

# ============================================================
# Public: init workdir (24h orphan sweep, mode 700)
# ============================================================
ccg_init() {
  local tmpbase="${TMPDIR:-/tmp}" uid
  uid=$(id -u 2>/dev/null)
  local sweep_age_min=1440
  for root in "$tmpbase" /tmp; do
    [ "$root" = "$tmpbase" ] || [ "$root" = "/tmp" ] || continue
    [ -d "$root" ] || continue
    if [ -n "$uid" ]; then
      find -L "$root" -maxdepth 1 -name 'ccg.*' -type d -user "$uid" -mmin "+$sweep_age_min" \
           -exec rm -rf {} + 2>/dev/null || true
    else
      find -L "$root" -maxdepth 1 -name 'ccg.*' -type d -mmin "+$sweep_age_min" \
           -exec rm -rf {} + 2>/dev/null || true
    fi
    [ "$tmpbase" = "/tmp" ] && break
  done

  local workdir
  workdir=$(mktemp -d -t "ccg.XXXXXXXX" 2>/dev/null) || workdir=$(mktemp -d 2>/dev/null)
  if [ -z "$workdir" ] || [ ! -d "$workdir" ]; then
    echo "CCG_INIT_FAIL=mktemp-failed" >&2
    return 1
  fi
  if [[ "$workdir" != *"/ccg."* ]]; then
    local renamed="${workdir%/*}/ccg.fallback.$$.${RANDOM:-x}"
    if mv "$workdir" "$renamed" 2>/dev/null; then workdir="$renamed"; fi
  fi
  chmod 700 "$workdir"
  printf 'CCG_DIR=%s\n' "$workdir"
  printf 'CCG_CODEX_PROMPT=%s\n' "$workdir/codex.prompt"
  printf 'CCG_GEMINI_PROMPT=%s\n' "$workdir/gemini.prompt"
  printf 'CCG_CODEX_RESULT=%s\n' "$workdir/codex.result"
  printf 'CCG_GEMINI_RESULT=%s\n' "$workdir/gemini.result"
  printf 'CCG_CODEX_ERR=%s\n'    "$workdir/codex.err"
  printf 'CCG_GEMINI_ERR=%s\n'   "$workdir/gemini.err"
  printf 'CCG_DIFF_FILE=%s\n'    "$workdir/diff.txt"
  printf 'CCG_SYNTHESIS_FILE=%s\n' "$workdir/synthesis.txt"
  printf 'CCG_RISK_FILE=%s\n'    "$workdir/risk.txt"
}

# ============================================================
# Public: preflight
# ============================================================
ccg_preflight() {
  if ! command -v codex >/dev/null 2>&1; then
    echo "CCG_PREFLIGHT_CODEX=missing"
  else
    echo "CCG_PREFLIGHT_CODEX=ok"
  fi

  if ! command -v gemini >/dev/null 2>&1; then
    echo "CCG_PREFLIGHT_GEMINI=missing"
    return 0
  fi

  local launcher
  if launcher=$(_ccg_pick_launcher GEMINI_API_KEY) && [ -n "$launcher" ] || \
     [ -n "${GEMINI_API_KEY:-}" ]; then
    echo "CCG_PREFLIGHT_GEMINI=ok"
    echo "CCG_GEMINI_LAUNCHER=${launcher:-direct}"
  else
    echo "CCG_PREFLIGHT_GEMINI=no-api-key"
  fi
}

# ============================================================
# Internal: prompt size guard
# ============================================================
_ccg_check_prompt_size() {
  local prompt_file="$1"
  local max_kb="${CCG_MAX_PROMPT_KB:-100}"
  local sz_b
  sz_b=$(wc -c <"$prompt_file" | tr -d ' ')
  local max_b=$((max_kb * 1024))
  if [ "$sz_b" -gt "$max_b" ]; then
    echo "prompt-too-large-${sz_b}b-max-${max_b}b"
    return 1
  fi
  return 0
}

# ============================================================
# Public: call Codex (cache-aware, usage-logged)
# ============================================================
ccg_codex() {
  local prompt_file="$1"
  local out_file="$2"
  local err_file="${out_file%.result}.err"
  local timeout_sec="${CCG_CODEX_TIMEOUT:-240}"

  if ! command -v codex >/dev/null 2>&1; then
    : > "$out_file"; echo "CCG_CODEX_FAIL=cli-missing"; return 127
  fi
  if [ ! -s "$prompt_file" ]; then
    : > "$out_file"; echo "CCG_CODEX_FAIL=empty-prompt"; return 2
  fi
  local oversize
  if ! oversize=$(_ccg_check_prompt_size "$prompt_file"); then
    : > "$out_file"; echo "CCG_CODEX_FAIL=$oversize"; return 2
  fi

  : > "$out_file"; : > "$err_file"

  local model
  model=$(_ccg_resolve_codex_model)

  # Cache lookup
  local cache_key cache_hit=""
  if cache_key=$(_ccg_cache_key "$prompt_file" "$model" 2>/dev/null) && [ -n "$cache_key" ]; then
    if cache_hit=$(_ccg_cache_lookup "$cache_key"); then
      cp "$cache_hit" "$out_file"
      local sz
      sz=$(wc -c <"$out_file" | tr -d ' ')
      local in_tok out_tok
      in_tok=$(_ccg_tokens_from_chars "$(wc -c <"$prompt_file" | tr -d ' ')")
      out_tok=$(_ccg_tokens_from_chars "$sz")
      _ccg_log_usage codex "$model" "$in_tok" "$out_tok" "0.000000" "1"
      echo "CCG_CODEX_OK=${sz}b cache=hit"
      return 0
    fi
  fi

  local ec=0
  _ccg_run_with_timeout "$timeout_sec" \
    codex exec --skip-git-repo-check -m "$model" --output-last-message "$out_file" - \
    < "$prompt_file" \
    > /dev/null \
    2> "$err_file" || ec=$?

  if [ "$ec" -eq 124 ]; then
    echo "CCG_CODEX_FAIL=timeout-${timeout_sec}s"; return 124
  fi
  if [ ! -s "$out_file" ]; then
    echo "CCG_CODEX_FAIL=empty-output"
    echo "--- err.log (redacted) ---"
    tail -5 "$err_file" 2>/dev/null | _ccg_redact
    return "$ec"
  fi
  local non_ws
  non_ws=$(tr -d '[:space:]' < "$out_file" | wc -c | tr -d ' ')
  if [ "$non_ws" -lt 1 ]; then
    echo "CCG_CODEX_FAIL=whitespace-only-output"; return 1
  fi

  local sz
  sz=$(wc -c <"$out_file" | tr -d ' ')

  # Log usage
  local in_tok out_tok in_price out_price usd
  in_tok=$(_ccg_tokens_from_chars "$(wc -c <"$prompt_file" | tr -d ' ')")
  out_tok=$(_ccg_tokens_from_chars "$sz")
  in_price=$(_ccg_price "$model" input)
  out_price=$(_ccg_price "$model" output)
  usd=$(awk -v ip="$in_price" -v op="$out_price" -v it="$in_tok" -v ot="$out_tok" \
        'BEGIN { printf "%.6f", (ip * it + op * ot) / 1000000 }')
  _ccg_log_usage codex "$model" "$in_tok" "$out_tok" "$usd" "0"

  # Store in cache
  [ -n "$cache_key" ] && _ccg_cache_store "$cache_key" "$out_file"

  echo "CCG_CODEX_OK=${sz}b"
  return 0
}

# ============================================================
# Public: call Gemini (cache-aware, usage-logged)
# ============================================================
ccg_gemini() {
  local prompt_file="$1"
  local out_file="$2"
  local err_file="${out_file%.result}.err"
  local timeout_sec="${CCG_GEMINI_TIMEOUT:-120}"

  local model
  model=$(_ccg_resolve_gemini_model)

  if ! command -v gemini >/dev/null 2>&1; then
    : > "$out_file"; echo "CCG_GEMINI_FAIL=cli-missing"; return 127
  fi
  if [ ! -s "$prompt_file" ]; then
    : > "$out_file"; echo "CCG_GEMINI_FAIL=empty-prompt"; return 2
  fi
  local oversize
  if ! oversize=$(_ccg_check_prompt_size "$prompt_file"); then
    : > "$out_file"; echo "CCG_GEMINI_FAIL=$oversize"; return 2
  fi

  : > "$out_file"; : > "$err_file"

  # Cache lookup
  local cache_key cache_hit=""
  if cache_key=$(_ccg_cache_key "$prompt_file" "$model" 2>/dev/null) && [ -n "$cache_key" ]; then
    if cache_hit=$(_ccg_cache_lookup "$cache_key"); then
      cp "$cache_hit" "$out_file"
      local sz
      sz=$(wc -c <"$out_file" | tr -d ' ')
      local in_tok out_tok
      in_tok=$(_ccg_tokens_from_chars "$(wc -c <"$prompt_file" | tr -d ' ')")
      out_tok=$(_ccg_tokens_from_chars "$sz")
      _ccg_log_usage gemini "$model" "$in_tok" "$out_tok" "0.000000" "1"
      echo "CCG_GEMINI_OK=${sz}b cache=hit"
      return 0
    fi
  fi

  local launcher_kind=""
  if [ -n "${GEMINI_API_KEY:-}" ]; then
    launcher_kind="direct"
  elif command -v zsh >/dev/null 2>&1 && \
       zsh -i -c "printenv GEMINI_API_KEY" 2>/dev/null | grep -q .; then
    launcher_kind="zsh"
  elif command -v bash >/dev/null 2>&1 && \
       bash -i -c "printenv GEMINI_API_KEY" 2>/dev/null | grep -q .; then
    launcher_kind="bash"
  fi
  case "${CCG_SHELL_LAUNCHER:-auto}" in
    none)   launcher_kind="direct" ;;
    zsh-i)  launcher_kind="zsh" ;;
    bash-i) launcher_kind="bash" ;;
  esac
  if [ -z "$launcher_kind" ] || \
     { [ "$launcher_kind" = "direct" ] && [ -z "${GEMINI_API_KEY:-}" ]; }; then
    echo "CCG_GEMINI_FAIL=no-api-key"; return 3
  fi

  local ec=0
  if [ "$launcher_kind" = "direct" ]; then
    _ccg_run_with_timeout "$timeout_sec" \
      gemini -m "$model" --output-format text \
      < "$prompt_file" > "$out_file" 2> "$err_file" || ec=$?
  elif [ "$launcher_kind" = "zsh" ]; then
    # shellcheck disable=SC2016
    _ccg_run_with_timeout "$timeout_sec" \
      env "_CCG_M=$model" "_CCG_P=$prompt_file" \
      zsh -i -c 'gemini -m "$_CCG_M" --output-format text < "$_CCG_P"' \
      > "$out_file" 2> "$err_file" || ec=$?
  else
    # shellcheck disable=SC2016
    _ccg_run_with_timeout "$timeout_sec" \
      env "_CCG_M=$model" "_CCG_P=$prompt_file" \
      bash -i -c 'gemini -m "$_CCG_M" --output-format text < "$_CCG_P"' \
      > "$out_file" 2> "$err_file" || ec=$?
  fi

  if [ "$ec" -eq 124 ]; then
    echo "CCG_GEMINI_FAIL=timeout-${timeout_sec}s"; return 124
  fi
  if [ ! -s "$out_file" ]; then
    echo "CCG_GEMINI_FAIL=empty-output"
    echo "--- err.log (redacted) ---"
    tail -5 "$err_file" 2>/dev/null | _ccg_redact
    return "$ec"
  fi
  local non_ws sz
  sz=$(wc -c <"$out_file" | tr -d ' ')
  non_ws=$(tr -d '[:space:]' < "$out_file" | wc -c | tr -d ' ')
  if [ "$non_ws" -lt 1 ]; then
    echo "CCG_GEMINI_FAIL=whitespace-only-output"; return 1
  fi
  if [ "$sz" -lt 800 ]; then
    if LC_ALL=C head -c 400 "$out_file" \
       | grep -qiE '^[[:space:]]*(\{"error"|\[?api error|error[: ]|❌|\bsettlement (blocked|unknown)|\bsafety_violation\b|\bcontent_filter\b|\bcontext (length|deadline) exceeded\b|\bENOTFOUND\b|\bECONNREFUSED\b|connection refused|API key not valid|key.*invalid|unauthorized|forbidden|quota.*exceeded|critical error)' \
       || LC_ALL=C head -c 400 "$out_file" \
          | grep -qE '"code":[[:space:]]*"[A-Z_]+_(BLOCKED|EXCEEDED|NOT_FOUND|INVALID|FAILED)"'; then
      echo "CCG_GEMINI_FAIL=error-leaked-to-stdout"
      echo "--- output sample (redacted) ---"
      LC_ALL=C head -c 200 "$out_file" | _ccg_redact
      return 1
    fi
  fi

  # Log usage
  local in_tok out_tok in_price out_price usd
  in_tok=$(_ccg_tokens_from_chars "$(wc -c <"$prompt_file" | tr -d ' ')")
  out_tok=$(_ccg_tokens_from_chars "$sz")
  in_price=$(_ccg_price "$model" input)
  out_price=$(_ccg_price "$model" output)
  usd=$(awk -v ip="$in_price" -v op="$out_price" -v it="$in_tok" -v ot="$out_tok" \
        'BEGIN { printf "%.6f", (ip * it + op * ot) / 1000000 }')
  _ccg_log_usage gemini "$model" "$in_tok" "$out_tok" "$usd" "0"

  [ -n "$cache_key" ] && _ccg_cache_store "$cache_key" "$out_file"

  echo "CCG_GEMINI_OK=${sz}b"
  return 0
}

# ============================================================
# Public: cleanup (path-traversal safe)
# ============================================================
ccg_cleanup() {
  local workdir="$1"
  if [ "${CCG_KEEP_ARTIFACTS:-0}" = "1" ]; then
    echo "CCG_CLEANUP=skipped (artifacts kept at $workdir)"
    return 0
  fi
  local normalized="${workdir%/}"
  local base="${normalized##*/}"
  if [ -n "$normalized" ] \
     && [ -d "$normalized" ] \
     && [ ! -L "$normalized" ] \
     && [[ "$normalized" == /* ]] \
     && [[ "$normalized" != *".."* ]] \
     && [[ "$base" == ccg.* ]]; then
    rm -rf "$normalized"
    echo "CCG_CLEANUP=done"
  else
    echo "CCG_CLEANUP=skipped (not a ccg workdir: $workdir)"
  fi
}

# ============================================================
# Dispatch guard: only when executed (not sourced).
# ============================================================
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -ge 1 ]; then
    cmd="$1"; shift
    case "$cmd" in
      init|preflight|codex|gemini|cleanup|actual|usage|diff_capture|risk_score|ledger_record|ledger_query|persist_report)
        "ccg_$cmd" "$@"
        ;;
      *)
        echo "Unknown subcommand: $cmd" >&2
        exit 2
        ;;
    esac
  fi
fi
