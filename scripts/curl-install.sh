#!/usr/bin/env bash
# curl-install.sh — one-line remote installer for /ccg.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mcgrapeng/ccg/main/scripts/curl-install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/mcgrapeng/ccg/main/scripts/curl-install.sh | bash -s -- --version v3.0.0
#
# What it does:
#   1. Downloads the requested release tarball from GitHub Releases (default: latest)
#   2. Extracts ccg.sh + ccg.md into ~/.claude/commands/
#   3. Runs preflight checks (Codex / Gemini / API key)
#
# No npm / Node.js required. Just bash + curl + tar.
set -eu

REPO="${CCG_REPO_OVERRIDE:-mcgrapeng/ccg}"
TAG="${CCG_VERSION:-latest}"
TARGET_DIR="${HOME}/.claude/commands"
TMPDIR="$(mktemp -d -t ccg-install.XXXXXXXX)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# parse flags
while [ $# -gt 0 ]; do
  case "$1" in
    --version) TAG="$2"; shift 2 ;;
    --version=*) TAG="${1#*=}"; shift ;;
    -h|--help)
      cat <<EOF
Usage: install.sh [--version <tag>]

Installs the /ccg slash command into ~/.claude/commands/ from GitHub Releases.

Options:
  --version <tag>    Install a specific release (default: latest)
                     Example: --version v3.0.0

Environment:
  CCG_REPO_OVERRIDE  Override repo (default: mcgrapeng/ccg)
EOF
      exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Resolve "latest" → actual tag via GitHub API (no auth required for public repos)
if [ "$TAG" = "latest" ]; then
  echo "→ Resolving latest release of $REPO ..."
  if command -v jq >/dev/null 2>&1; then
    TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | jq -r .tag_name)
  else
    TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | grep -E '"tag_name"' | head -1 | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')
  fi
  [ -n "$TAG" ] && [ "$TAG" != "null" ] || { echo "FATAL: could not resolve latest release tag" >&2; exit 2; }
fi
echo "→ Installing $REPO@$TAG"

TARBALL_URL="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"
ARCHIVE="$TMPDIR/ccg.tar.gz"

echo "→ Downloading $TARBALL_URL"
curl -fsSL -o "$ARCHIVE" "$TARBALL_URL" || { echo "FATAL: download failed" >&2; exit 2; }

echo "→ Extracting"
tar -xzf "$ARCHIVE" -C "$TMPDIR"
SRC_DIR=$(find "$TMPDIR" -maxdepth 1 -type d -name 'ccg-*' | head -1)
[ -d "$SRC_DIR" ] || { echo "FATAL: extracted dir not found" >&2; exit 2; }

[ -r "$SRC_DIR/ccg.sh" ] || { echo "FATAL: ccg.sh missing in archive" >&2; exit 2; }
[ -r "$SRC_DIR/ccg.md" ] || { echo "FATAL: ccg.md missing in archive" >&2; exit 2; }

echo "→ Installing to $TARGET_DIR"
mkdir -p "$TARGET_DIR"
install -m 0755 "$SRC_DIR/ccg.sh" "$TARGET_DIR/ccg.sh"
install -m 0644 "$SRC_DIR/ccg.md" "$TARGET_DIR/ccg.md"
echo "  ✓ $TARGET_DIR/ccg.sh"
echo "  ✓ $TARGET_DIR/ccg.md"

echo
echo "→ Preflight checks:"
. "$TARGET_DIR/ccg.sh"
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
echo "✓ Installed @ $TAG. Open Claude Code and type: /ccg"
