#!/usr/bin/env bash
# install.sh — installs claude-switch to ~/.local/bin
set -euo pipefail

BIN_DIR="$HOME/.local/bin"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$BIN_DIR/claude-switch"
TARGET_ALIAS="$BIN_DIR/csw"

# Check uv
if ! command -v uv &>/dev/null; then
  echo "❌  uv not found."
  echo ""
  echo "    Install it first:"
  echo "      curl -LsSf https://astral.sh/uv/install.sh | sh"
  echo "    or:"
  echo "      brew install uv"
  exit 1
fi

mkdir -p "$BIN_DIR"

# Write wrapper inline so REPO_DIR is baked in at install time
cat > "$TARGET" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if ! command -v uv &>/dev/null; then
  echo "❌  uv not found."
  echo "    Install: curl -LsSf https://astral.sh/uv/install.sh | sh"
  exit 1
fi

exec uv run "${REPO_DIR}/claude_switch.py" "\$@"
EOF

ln -sf "$TARGET" "$TARGET_ALIAS"

chmod +x "$TARGET"
chmod +x "$TARGET_ALIAS"

# Ensure BIN_DIR is in PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo ""
  echo "⚠️   $BIN_DIR is not in your PATH."
  echo "    Add this to your ~/.zshrc:"
  echo ""
  echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
fi

echo "✅  Installed → $TARGET"
echo "    Aliased → $TARGET_ALIAS"
echo "    Pointing to: ${REPO_DIR}/claude_switch.py"
echo ""
echo "Usage:"
echo "  claude-switch save work"
echo "  claude-switch save personal"
echo "  claude-switch pick"
