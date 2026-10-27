# Install

## Option 1 — download binary (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/mtxr/claude-switch/main/install.sh | bash
```

This downloads the latest release binary for your OS and architecture (macOS or Linux, arm64 or x86_64) to `~/.local/bin/csw` and creates a `claude-switch` alias next to it.

## Option 2 — build from source

Requires [Zig 0.17.0](https://ziglang.org/download/) (or install via [mise](https://mise.jdx.dev): `mise use zig@0.17.0`).

```bash
git clone https://github.com/mtxr/claude-switch
cd claude-switch
zig build -Doptimize=ReleaseSmall
cp zig-out/bin/csw ~/.local/bin/csw
```

## Option 3 — manual download

Grab the binary for your platform from [Releases](https://github.com/mtxr/claude-switch/releases), put it somewhere in your `$PATH`, and `chmod +x` it.

## Option 4 — package managers

| Channel | Command |
|---|---|
| Homebrew (macOS and Linux) | `brew install mtxr/tap/csw` (`mtxr/tap/claude-switch` is an alias) |
| mise (macOS and Linux) | `mise use -g github:mtxr/claude-switch` |
| Nix (Apple Silicon macOS and Linux; Intel Macs are not supported) | `nix run github:mtxr/claude-switch` or `nix profile install github:mtxr/claude-switch`. This fetches the latest release binary (hash pinned in `packaging/nix/release.json`, so no compile). To build from source use `nix run github:mtxr/claude-switch#csw-src` |
| Debian, Ubuntu | `sudo apt install ./csw_<version>_<amd64\|arm64>.deb` from [Releases](https://github.com/mtxr/claude-switch/releases) |
| Fedora, RHEL | `sudo dnf install ./csw-<version>-1.<x86_64\|aarch64>.rpm` from Releases |

The Linux binaries are static, so they run on any distribution. The packages also install the `claude-switch` alias and bash, zsh and fish completions and the man page.

Windows is not supported natively. Under WSL, use any of the Linux options above.

## Edge channel

`edge` is a rolling pre-release rebuilt from `main` whenever the code changes. It is unstable and meant for trying changes early; the release notes on the [edge release](https://github.com/mtxr/claude-switch/releases/tag/edge) list what changed since the last stable version.

- Install it with `CSW_CHANNEL=edge` set for `install.sh`.
- Switch an existing install with `csw update --edge`. Repeat it to follow new edge builds. `csw --version` shows `<version>-edge+<commit>`.
- Edge downloads are verified against the release `SHA256SUMS` like stable ones.
- To leave edge, wait for the next stable release and run `csw update`, or reinstall stable with the plain install script. Package-manager installs always follow stable, and `csw update --edge` on them explains how to switch to a standalone install.

## Verifying a download

Every release ships a `SHA256SUMS` file, and each binary and `SHA256SUMS` carry a GitHub build provenance attestation. `install.sh` checks the checksum before installing and refuses to install on a mismatch. To verify a manual download:

```bash
shasum -a 256 -c SHA256SUMS --ignore-missing
gh attestation verify csw-aarch64-apple-darwin --repo mtxr/claude-switch
```

Make sure `~/.local/bin` is in your `$PATH` (add to `~/.zshrc` if needed):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

The interactive picker uses [sk](https://github.com/lotabout/skim) or [fzf](https://github.com/junegunn/fzf) when one is on your `PATH`, and a small built-in numbered list otherwise. Installing one is optional and only adds fuzzy search:

```bash
brew install sk
```
