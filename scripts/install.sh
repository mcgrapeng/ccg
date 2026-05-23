#!/usr/bin/env bash
# install.sh — install /ccg into ~/.claude/commands for Claude Code.
# Idempotent; safe to re-run for upgrades. Pass --dry-run to preview.
set -eu

DRY=0
case "${1:-}" in
  --dry-run|-n) DRY=1 ;;
  --help|-h)
    cat <<EOF
Usage: $0 [--dry-run]
Installs ccg.md + ccg.sh into ~/.claude/commands/ so /ccg becomes available
in Claude Code. Also runs preflight checks for Codex CLI / Gemini CLI / API key.
EOF
    exit 0 ;;
esac

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CCG_SH="$HERE/ccg.sh"
CCG_MD="$HERE/ccg.md"
TARGET_DIR="${HOME}/.claude/commands"

[ -r "$CCG_SH" ] || { echo "FATAL: $CCG_SH not found"; exit 2; }
[ -r "$CCG_MD" ] || { echo "FATAL: $CCG_MD not found"; exit 2; }

echo "→ Installing /ccg to: $TARGET_DIR"

if [ "$DRY" = "0" ]; then
  mkdir -p "$TARGET_DIR"
  install -m 0755 "$CCG_SH" "$TARGET_DIR/ccg.sh"
  install -m 0644 "$CCG_MD" "$TARGET_DIR/ccg.md"
  echo "  ✓ wrote $TARGET_DIR/ccg.sh ($(wc -l <"$CCG_SH" | tr -d ' ') lines)"
  echo "  ✓ wrote $TARGET_DIR/ccg.md"
else
  echo "  [dry-run] would write: $TARGET_DIR/{ccg.sh,ccg.md}"
fi

echo
echo "→ Preflight checks:"
. "$CCG_SH"
out=$(ccg_preflight)
echo "$out" | sed 's/^/  /'

if echo "$out" | grep -q "CCG_PREFLIGHT_CODEX=missing"; then
  echo "  ⚠ install: npm i -g @openai/codex"
fi
if echo "$out" | grep -q "CCG_PREFLIGHT_GEMINI=missing"; then
  echo "  ⚠ install: npm i -g @google/gemini-cli"
fi
if echo "$out" | grep -q "CCG_PREFLIGHT_GEMINI=no-api-key"; then
  echo "  ⚠ add to ~/.zshenv: export GEMINI_API_KEY=<your-key>"
fi

echo
echo "→ Done. Open a new Claude Code session and type: /ccg <your task>"
