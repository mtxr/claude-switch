#!/bin/sh
set -eu
expires=$(( ($(date +%s) + 2592000) * 1000 ))

seed_profile() {
  name=$1
  email=$2
  org=$3
  plan=$4
  mkdir -p "$HOME/.claude.$name"
  printf '{"oauthAccount":{"emailAddress":"%s","organizationName":"%s"}}\n' "$email" "$org" > "$HOME/.claude.$name/.claude.json"
  printf '{"claudeAiOauth":{"accessToken":"demo-access-%s","refreshToken":"demo-refresh-%s","expiresAt":%s,"subscriptionType":"%s","rateLimitTier":"default"}}\n' "$name" "$name" "$expires" "$plan" > "$HOME/.claude.$name/.credentials.json"
  chmod 600 "$HOME/.claude.$name/.credentials.json"
}

seed_profile work ada@acme.example "Acme Inc" team
seed_profile personal ada@home.example "" pro
seed_profile oss ada@oss.example "Open Source" max
ln -s "$HOME/.claude.work" "$HOME/.claude"
ln -s ".claude/.claude.json" "$HOME/.claude.json"
printf "PS1='%s '\n" '$' > "$HOME/.bashrc"
