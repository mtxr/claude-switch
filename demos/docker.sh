#!/bin/sh
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-$repo/docs/demos}
bin=$(mktemp -d)
mkdir -p "$out"

docker run --rm --init \
  -v "$repo":/src:ro \
  -v "$bin":/bin-out \
  -v csw-demos-nix:/nix \
  nixos/nix sh -ec '
    mkdir /work
    tar -C /src --exclude=.git --exclude=.zig-cache --exclude=zig-out -cf - . | tar -C /work -xf -
    nix --extra-experimental-features "nix-command flakes" build path:/work#csw -o /tmp/csw-result
    cp /tmp/csw-result/bin/csw /bin-out/csw
  '

docker run --rm --init --shm-size=1g \
  --entrypoint sh \
  -v "$bin/csw":/usr/local/bin/csw:ro \
  -v "$repo/demos":/demos:ro \
  -v "$out":/vhs \
  ghcr.io/charmbracelet/vhs \
  -ec '
    export HOME=/home/ada
    mkdir -p "$HOME" /tmp/bin
    install -m 755 /demos/fake-claude.sh /tmp/bin/claude
    export PATH="/tmp/bin:$PATH"
    apt-get update -qq >/dev/null
    apt-get install -y -qq tmux >/dev/null
    cd /vhs
    for tape in /demos/*.tape; do
      rm -rf "$HOME"
      mkdir -p "$HOME"
      sh /demos/seed.sh
      vhs "$tape"
    done
  '

rm -rf "$bin"
