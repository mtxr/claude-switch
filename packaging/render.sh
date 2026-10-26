#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: render.sh <homebrew|aur|nix> <version> <SHA256SUMS>" >&2
  exit 2
fi

kind="$1"
version="$2"
sums="$3"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$kind" in
  homebrew) template="$here/homebrew/csw.rb" ;;
  aur) template="$here/aur/PKGBUILD" ;;
  nix) template="$here/nix/release.json.in" ;;
  *) echo "unknown kind: $kind" >&2; exit 2 ;;
esac

sha_of() {
  local asset="$1" sha
  sha=$(awk -v asset="$asset" '$2 == asset { print $1 }' "$sums")
  if [ -z "$sha" ]; then
    echo "asset $asset is missing from $sums" >&2
    exit 1
  fi
  printf '%s' "$sha"
}

sha_aarch64_darwin=$(sha_of csw-aarch64-apple-darwin)
sha_x86_64_darwin=$(sha_of csw-x86_64-apple-darwin)
sha_aarch64_linux=$(sha_of csw-aarch64-unknown-linux-musl)
sha_x86_64_linux=$(sha_of csw-x86_64-unknown-linux-musl)

sed \
  -e "s/@VERSION@/${version}/g" \
  -e "s/@SHA_AARCH64_DARWIN@/${sha_aarch64_darwin}/g" \
  -e "s/@SHA_X86_64_DARWIN@/${sha_x86_64_darwin}/g" \
  -e "s/@SHA_AARCH64_LINUX@/${sha_aarch64_linux}/g" \
  -e "s/@SHA_X86_64_LINUX@/${sha_x86_64_linux}/g" \
  "$template"
