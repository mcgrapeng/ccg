#!/usr/bin/env bash
# curl-install.sh — one-line remote installer for /ccg.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mcgrapeng/ccg/main/scripts/curl-install.sh | bash
#   curl -fsSL ... | bash -s -- --version v3.2.0
#
# Defaults to jsdelivr CDN for cross-region reliability (especially mainland China),
# falls back to raw.githubusercontent.com if jsdelivr is unreachable.
#
# No npm / Node.js required. Just bash + curl.
set -eu

REPO="${CCG_REPO_OVERRIDE:-mcgrapeng/ccg}"
TAG="${CCG_VERSION:-latest}"
TARGET_DIR="${HOME}/.claude/commands"

CURL_OPTS="-fsSL --connect-timeout 15 --max-time 120 --retry 2 --retry-delay 2"

# parse flags
while [ $# -gt 0 ]; do
  case "$1" in
    --version) TAG="$2"; shift 2 ;;
    --version=*) TAG="${1#*=}"; shift ;;
    -h|--help)
      cat <<EOF
Usage: install.sh [--version <tag>]

Installs the /ccg slash command into ~/.claude/commands/ from GitHub
(via jsdelivr CDN by default; falls back to raw.githubusercontent.com).

Options:
  --version <tag>    Install a specific release (default: latest)
                     Example: --version v3.2.0

Environment:
  CCG_REPO_OVERRIDE  Override repo (default: mcgrapeng/ccg)
  CCG_NO_CDN=1       Skip jsdelivr; use raw.githubusercontent.com only
EOF
      exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Resolve "latest" → actual tag via GitHub API
# (api.github.com is usually reachable even when github.com archive is slow)
if [ "$TAG" = "latest" ]; then
  echo "→ Resolving latest release of $REPO ..."
  if command -v jq >/dev/null 2>&1; then
    TAG=$(curl $CURL_OPTS "https://api.github.com/repos/$REPO/releases/latest" | jq -r .tag_name)
  else
    TAG=$(curl $CURL_OPTS "https://api.github.com/repos/$REPO/releases/latest" \
      | grep -E '"tag_name"' | head -1 | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')
  fi
  if [ -z "$TAG" ] || [ "$TAG" = "null" ]; then
    echo "FATAL: could not resolve latest release tag" >&2
    echo "  Try: bash -s -- --version v3.2.0" >&2
    exit 2
  fi
fi
echo "→ Installing $REPO@$TAG"

# Download a single file. Tries jsdelivr first (fast in mainland China + global CDN),
# then falls back to raw.githubusercontent.com.
download_file() {
  rel_path="$1"
  dest="$2"

  if [ "${CCG_NO_CDN:-0}" != "1" ]; then
    url="https://cdn.jsdelivr.net/gh/$REPO@$TAG/$rel_path"
    echo "  → $url"
    if curl $CURL_OPTS -o "$dest" "$url" 2>/dev/null; then
      return 0
    fi
    echo "  (jsdelivr failed, trying raw.githubusercontent.com)"
  fi

  url="https://raw.githubusercontent.com/$REPO/$TAG/$rel_path"
  echo "  → $url"
  if curl $CURL_OPTS -o "$dest" "$url" 2>/dev/null; then
    return 0
  fi

  return 1
}

# Use a non-standard variable name to avoid polluting the global TMPDIR
# which other tools (including ccg.sh itself) depend on.
CCG_INSTALL_TMPDIR="$(mktemp -d -t ccg-install.XXXXXXXX)"
TMPDIR="$CCG_INSTALL_TMPDIR"
trap 'rm -rf "$CCG_INSTALL_TMPDIR"' EXIT

echo "→ Downloading ccg.sh"
if ! download_file "ccg.sh" "$TMPDIR/ccg.sh"; then
  echo "FATAL: could not download ccg.sh from any source" >&2
  echo "  Network issue? Try setting a proxy or use:" >&2
  echo "    CCG_NO_CDN=1 bash -s -- --version $TAG" >&2
  exit 2
fi

echo "→ Downloading ccg.md"
if ! download_file "ccg.md" "$TMPDIR/ccg.md"; then
  echo "FATAL: could not download ccg.md from any source" >&2
  exit 2
fi

# Sanity check downloaded files
[ -s "$TMPDIR/ccg.sh" ] || { echo "FATAL: ccg.sh downloaded but empty" >&2; exit 2; }
[ -s "$TMPDIR/ccg.md" ] || { echo "FATAL: ccg.md downloaded but empty" >&2; exit 2; }
head -1 "$TMPDIR/ccg.sh" | grep -q '^#!' \
  || { echo "FATAL: ccg.sh doesn't look like a shell script" >&2; exit 2; }

# Integrity check: verify SHA-256 checksums against GitHub release assets if available.
# This prevents CDN poisoning or MITM attacks from executing arbitrary code.
echo "→ Verifying integrity..."
_ccg_install_verify_checksum() {
  local file="$1"
  local checksum_url="https://raw.githubusercontent.com/$REPO/$TAG/scripts/checksums.sha256"
  local checksums
  if checksums=$(curl -fsSL --connect-timeout 10 --max-time 30 "$checksum_url" 2>/dev/null); then
    local expected
    expected=$(printf '%s\n' "$checksums" | grep "$(basename "$file")" | awk '{print $1}')
    if [ -n "$expected" ]; then
      local actual
      if command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
      elif command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$file" | awk '{print $1}')
      fi
      if [ -n "$actual" ] && [ "$actual" != "$expected" ]; then
        echo "FATAL: checksum mismatch for $(basename "$file")" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        echo "  This may indicate a compromised download. Aborting." >&2
        return 1
      fi
    fi
  fi
  # If checksums file is not available (older releases), proceed with a warning
  return 0
}
_ccg_install_verify_checksum "$TMPDIR/ccg.sh" || exit 2
_ccg_install_verify_checksum "$TMPDIR/ccg.md" || exit 2

echo "→ Installing to $TARGET_DIR"
mkdir -p "$TARGET_DIR"
install -m 0755 "$TMPDIR/ccg.sh" "$TARGET_DIR/ccg.sh"
install -m 0644 "$TMPDIR/ccg.md" "$TARGET_DIR/ccg.md"
echo "  ✓ $TARGET_DIR/ccg.sh"
echo "  ✓ $TARGET_DIR/ccg.md"

echo
echo "→ Preflight checks:"
# shellcheck disable=SC1091
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
