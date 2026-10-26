#!/bin/sh
set -eu
expires=$(( ($(date +%s) + 2592000) * 1000 ))

seed_profile() {
  name=$1
  email=$2
  org=$3
  plan=$4
  mkdir -p "$HOME/.claude.$name"
  printf '{"oauthAccount":{"emailAddress":"%s","organizationName":"%s"}}\n' "$email" "$org" > "$HOME/.claude.$name.json"
  printf '{"claudeAiOauth":{"accessToken":"demo-access-%s","refreshToken":"demo-refresh-%s","expiresAt":%s,"subscriptionType":"%s","rateLimitTier":"default"}}\n' "$name" "$name" "$expires" "$plan" > "$HOME/.claude.$name/.credentials.json"
  chmod 600 "$HOME/.claude.$name/.credentials.json"
  ln -s "$HOME/.claude.$name.json" "$HOME/.claude.$name/.claude.json"
}

seed_profile work ada@acme.example "Acme Inc" team
seed_profile personal ada@home.example "" pro
seed_profile oss ada@oss.example "Open Source" max
ln -s "$HOME/.claude.work.json" "$HOME/.claude.json"
ln -s "$HOME/.claude.work" "$HOME/.claude"
printf "PS1='%s '\n" '$' > "$HOME/.bashrc"
