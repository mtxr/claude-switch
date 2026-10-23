#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: build-packages.sh <version> <binary-dir> <output-dir>" >&2
  exit 2
fi

version="$1"
bindir="$(cd "$2" && pwd)"
outdir="$3"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

NFPM_VERSION="2.47.0"
NFPM_LINUX_X86_64_SHA256="0660ca602b2d2d2ae4781a06c692b3eeb9d437ffea05b831d76e41f4a3188783"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$outdir"
outdir="$(cd "$outdir" && pwd)"

if ! command -v nfpm >/dev/null 2>&1; then
  tarball="nfpm_${NFPM_VERSION}_Linux_x86_64.tar.gz"
  curl -fsSL -o "$work/$tarball" "https://github.com/goreleaser/nfpm/releases/download/v${NFPM_VERSION}/${tarball}"
  echo "${NFPM_LINUX_X86_64_SHA256}  $work/$tarball" | sha256sum -c -
  mkdir -p "$work/bin"
  tar -xzf "$work/$tarball" -C "$work/bin" nfpm
  export PATH="$work/bin:$PATH"
fi

completions="$work/completions"
mkdir -p "$completions"
"$bindir/csw-x86_64-unknown-linux-musl" completion bash > "$completions/csw.bash"
"$bindir/csw-x86_64-unknown-linux-musl" completion zsh > "$completions/_csw"

cd "$repo"
for pair in amd64:x86_64-unknown-linux-musl arm64:aarch64-unknown-linux-musl; do
  arch="${pair%%:*}"
  asset="csw-${pair#*:}"
  for packager in deb rpm; do
    config="$work/nfpm-${arch}.yaml"
    sed -e "s|\${BINARY}|$bindir/$asset|" -e "s|\${COMPLETION_DIR}|$completions|" packaging/nfpm.yaml > "$config"
    VERSION="$version" ARCH="$arch" \
      nfpm package --config "$config" --packager "$packager" --target "$outdir"
  done
done
