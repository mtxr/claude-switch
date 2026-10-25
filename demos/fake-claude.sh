#!/bin/sh
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  config="$CLAUDE_CONFIG_DIR/.claude.json"
else
  config="$HOME/.claude.json"
fi
email=$(sed -n 's/.*"emailAddress": *"\([^"]*\)".*/\1/p' "$config" 2>/dev/null | head -n 1)
printf 'Claude Code (demo)\n'
printf '  account: %s\n' "${email:-not logged in}"
printf '  config:  %s\n' "${CLAUDE_CONFIG_DIR:-~/.claude}"
