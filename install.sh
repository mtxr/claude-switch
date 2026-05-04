#!/usr/bin/env bash
# install.sh — download and install the latest csw binary from GitHub releases
set -euo pipefail

REPO="mtxr/claude-switch"
BIN_DIR="$HOME/.local/bin"
BINARY="csw"
ALIAS="claude-switch"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  arm64 | aarch64) ARCH="aarch64" ;;
  x86_64) ARCH="x86_64" ;;
  *)
    echo "❌  Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

# Get latest release tag
echo "➜   Fetching latest release..."
LATEST=$(curl -s -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/releases/latest" |
  grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')

if [ -z "$LATEST" ]; then
  echo "❌  Could not determine latest release."
  echo "    Check: https://github.com/${REPO}/releases"
  exit 1
fi

URL="https://github.com/${REPO}/releases/download/v${LATEST}/${BINARY}-${ARCH}-apple-darwin"

mkdir -p "$BIN_DIR"

echo "➜   Downloading csw v${LATEST} for ${ARCH}..."
curl -L --fail -o "${BIN_DIR}/${BINARY}" "$URL"
chmod +x "${BIN_DIR}/${BINARY}"

# Create claude-switch alias
ln -sf "${BIN_DIR}/${BINARY}" "${BIN_DIR}/${ALIAS}"

# Ensure BIN_DIR is in PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo ""
  echo "⚠️   $BIN_DIR is not in your PATH."
  echo "    Add this to your ~/.zshrc or ~/.zprofile:"
  echo ""
  echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
fi

echo "✅  csw v${LATEST} installed to ${BIN_DIR}/${BINARY}"
echo "    Alias: ${BIN_DIR}/${ALIAS}"
echo ""
echo "Usage:"
echo "  csw save work"
echo "  csw save personal"
echo "  csw pick"
