#!/usr/bin/env bash
# install.sh — download and install the latest csw binary from GitHub releases
set -euo pipefail

REPO="mtxr/claude-switch"
BIN_DIR="$HOME/.local/bin"
BINARY="csw"
ALIAS="claude-switch"

# Detect OS
case "$(uname -s)" in
  Darwin) TARGET_SUFFIX="apple-darwin" ;;
  Linux) TARGET_SUFFIX="unknown-linux-musl" ;;
  *)
    echo "❌  Unsupported OS: $(uname -s)"
    exit 1
    ;;
esac

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

ASSET="${BINARY}-${ARCH}-${TARGET_SUFFIX}"
BASE_URL="https://github.com/${REPO}/releases/download/v${LATEST}"

mkdir -p "$BIN_DIR"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "➜   Downloading csw v${LATEST} for ${ARCH}..."
curl -L --fail -o "${WORK_DIR}/${ASSET}" "${BASE_URL}/${ASSET}"

echo "➜   Verifying checksum..."
if ! curl -L --fail -s -o "${WORK_DIR}/SHA256SUMS" "${BASE_URL}/SHA256SUMS"; then
  echo "❌  Could not download SHA256SUMS for v${LATEST}. Refusing to install an unverified binary."
  exit 1
fi

EXPECTED=$(awk -v asset="$ASSET" '$2 == asset { print $1 }' "${WORK_DIR}/SHA256SUMS")
if [ -z "$EXPECTED" ]; then
  echo "❌  ${ASSET} is not listed in SHA256SUMS. Refusing to install an unverified binary."
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL=$(sha256sum "${WORK_DIR}/${ASSET}" | awk '{ print $1 }')
else
  ACTUAL=$(shasum -a 256 "${WORK_DIR}/${ASSET}" | awk '{ print $1 }')
fi

if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "❌  Checksum mismatch for ${ASSET}."
  echo "    expected: ${EXPECTED}"
  echo "    actual:   ${ACTUAL}"
  exit 1
fi

chmod +x "${WORK_DIR}/${ASSET}"
mv -f "${WORK_DIR}/${ASSET}" "${BIN_DIR}/${BINARY}"

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
echo "    Checksum verified. To verify build provenance: gh attestation verify ${BIN_DIR}/${BINARY} --repo ${REPO}"
echo ""
echo "Usage:"
echo "  csw save work"
echo "  csw save personal"
echo "  csw pick"
