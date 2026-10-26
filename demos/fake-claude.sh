#!/bin/sh
dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  config="$CLAUDE_CONFIG_DIR/.claude.json"
else
  config="$HOME/.claude.json"
fi
field() {
  sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "$2" 2>/dev/null | head -n 1
}
email=$(field emailAddress "$config")
org=$(field organizationName "$config")
plan=$(field subscriptionType "$dir/.credentials.json")
orange='\033[38;5;209m'
dim='\033[2m'
bold='\033[1m'
reset='\033[0m'
width=62
line() {
  printf "${orange}│${reset} %-$((width - 2))s ${orange}│${reset}\n" "$1"
}
rule() {
  printf "${orange}%s%s%s${reset}\n" "$1" "$(printf '─%.0s' $(seq 1 $width))" "$2"
}
rule ╭ ╮
if [ -n "$email" ]; then
  printf "${orange}│${reset} ${orange}✻${reset} ${bold}%-$((width - 4))s${reset} ${orange}│${reset}\n" "Welcome to Claude Code"
  line ""
  line "  ${email}"
  line "  ${org:+$org - }Claude ${plan:-Pro}"
else
  printf "${orange}│${reset} ${orange}✻${reset} ${bold}%-$((width - 4))s${reset} ${orange}│${reset}\n" "Welcome to Claude Code"
  line ""
  line "  Not logged in · Run /login"
fi
line ""
line "  cwd: $(pwd | sed "s|^$HOME|~|")"
rule ╰ ╯
printf '\n'
rule ╭ ╮
line ">"
rule ╰ ╯
printf "${dim}  ? for shortcuts${reset}\n"
