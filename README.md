# claude-switch

Swap between Claude Code accounts on macOS and Linux with a single command. Claude Desktop (macOS) is selected with `--desktop` or `--all`.

**Fully offline. Zero storage.** No tokens are sent anywhere and nothing is written to disk by csw. All credentials live exclusively in macOS Keychain — the same encrypted, hardware-backed store that Claude itself uses. No config files, no dotfiles, no plaintext secrets.

## Install

### Option 1 — download binary (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/mtxr/claude-switch/main/install.sh | bash
```

This downloads the latest release binary for your architecture (arm64 or x86_64) to `~/.local/bin/csw`.

### Option 2 — build from source

Requires [Zig 0.16.0](https://ziglang.org/download/) (or install via [mise](https://mise.jdx.dev): `mise use zig@0.16.0`).

```bash
git clone https://github.com/mtxr/claude-switch
cd claude-switch
zig build -Doptimize=ReleaseSmall
# binary at: zig-out/bin/csw
cp zig-out/bin/csw ~/.local/bin/csw
```

### Option 3 — manual download

Grab the binary for your architecture from [Releases](https://github.com/mtxr/claude-switch/releases), put it somewhere in your `$PATH`, and `chmod +x` it.

---

Make sure `~/.local/bin` is in your `$PATH` (add to `~/.zshrc` if needed):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

You also need [sk](https://github.com/lotabout/skim) or [fzf](https://github.com/junegunn/fzf) for the interactive picker:

```bash
brew install sk
```

## Migrating from the Python version

If you were using the previous Python-based `csw`, your profiles and keychain entries are **fully compatible** — no data migration needed. The Zig binary reads the exact same Keychain entries and file paths.

The only thing that changes is how `csw` is installed:

**1. Remove the old wrapper**

```bash
rm ~/.local/bin/csw ~/.local/bin/claude-switch
```

**2. Install the new binary**

```bash
curl -fsSL https://raw.githubusercontent.com/mtxr/claude-switch/main/install.sh | bash
```

**3. Verify everything still works**

```bash
csw whoami
csw list
```

Your profiles should appear exactly as before. Nothing to re-save.

> **Note:** `csw update` now self-updates by downloading the latest binary from GitHub Releases instead of running `git pull`. If you cloned the repo just for the Python version, you can delete it.

## Getting started

You need to save each account as a profile before you can switch between them. Do this once per account:

**1. Save your current account (e.g. work)**

```bash
csw save work
```

This saves the session tokens into macOS Keychain and migrates `~/.claude.json` and `~/.claude/` to profile-specific paths (`~/.claude.work.json`, `~/.claude.work/`), leaving symlinks in place. From now on, switching just swaps the symlinks.

**2. Create a slot for the second account and log in**

```bash
csw new personal   # creates ~/.claude.personal.json + ~/.claude.personal/, activates symlinks
claude auth login  # logs in as the personal account into the active slot
```

**3. Save the second account**

```bash
csw save personal
```

You're set. Switch between accounts instantly:

```bash
csw use work
csw use personal
# or interactively:
csw pick
```

## Usage

```
csw save <name>    Save the current Claude Code session as a named profile
csw use <name>     Switch Claude Code to a saved profile
csw new <name>     Create a new empty profile slot (then: claude auth login)
csw delete <name>  Delete a profile and its data
csw list           List all saved profiles
csw whoami         Show active session info (Code + Desktop + saved profiles)
csw pick           Interactive fuzzy picker (sk / fzf)
csw update         Update csw to the latest release
csw logout-all     Log out of all accounts and remove active symlinks
```

## Linux

`csw` builds and runs on Linux (x86_64 and aarch64; `install.sh` and `csw update` pick the `unknown-linux-musl` asset). Supported: `save`, `use`, `new`, `delete`, `list`, `pick`, `whoami` (Claude Code), `logout-all`, `doctor`.

On Linux, Claude Code keeps its credentials in `~/.claude/.credentials.json` (mode 0600). Because `~/.claude/` is a symlink to the active profile directory, credentials switch together with the profile; csw never reads them into another store or rewrites them. Claude Desktop and Keychain features are macOS-only and report "not supported" on Linux.

## How it works

### Security model

csw does not create any files or directories of its own. All session tokens are stored in **macOS Keychain**, protected by the same OS-level encryption and access controls that guard your passwords, SSH keys, and certificates.

| Data | Where it lives |
|---|---|
| Claude Code tokens | Keychain: `csw-code-<profile>` |
| Active Code session | Keychain: `Claude Code-credentials` (managed by Claude) |
| Active Desktop session | Electron SQLite cookie, AES-128-CBC encrypted (managed by Claude Desktop) |
| Desktop encryption key | Keychain: `Claude Safe Storage` (managed by Claude Desktop) |
| Profile configs | `~/.claude.<profile>.json` + `~/.claude.<profile>/` |
| Active profile | `~/.claude.json` → symlink, `~/.claude/` → symlink |

- No network requests are ever made.
- No plaintext tokens ever touch the filesystem.
- Claude Code is the default. Claude Desktop is only touched when you pass `--desktop` or `--all`, and is then quit and relaunched where a swap is needed.

### Claude Desktop (`--desktop`, `--all`)

Code and Desktop keep independent state, so a profile can be on one account in Claude Code and another in Claude Desktop. The mutating commands (`save`, `use`, `new`, `delete`, `list`, `pick`, `logout-all`) choose what they act on:

| Flag | Acts on |
|---|---|
| none | Claude Code only |
| `--desktop` | Claude Desktop only |
| `--all` | Claude Code and Claude Desktop together |

What each command does for Desktop:

| Command | Desktop effect |
|---|---|
| `csw save <name> --desktop` | Assigns the Desktop data dir to the profile (if it has no owner yet). |
| `csw use <name> --desktop` | Quits Desktop, swaps the data dirs and reopens it. Claude Code stays where it is. |
| `csw new <name> --desktop` | Creates the profile and swaps Desktop to an empty data dir to log in. |
| `csw delete <name> --desktop` | Removes `Claude.<name>/` and clears the Desktop owner if it was that profile. Without the flag the Desktop data is kept. |
| `csw list --desktop` | Marks only the Desktop profile (`--all` marks `◀ code` and `◀ desktop`). |
| `csw pick --desktop` | `use --desktop` for the chosen profile. |
| `csw logout-all --desktop` | Quits Desktop and removes the legacy Desktop symlink. |

`csw whoami` and `csw doctor` are read-only and always report both products, including which profile owns the Desktop data dir (and warn when it is unassigned or points at a deleted profile).

csw records the owner of the main Desktop data dir in `Claude/.csw-profile`; the marker travels with the dir when it is renamed. Installs that predate the marker are assigned to the active Code profile the first time `use` or `new` runs, which matches how older versions always switched both together.

### Profile switching

Switching profiles is instant because `~/.claude.json` and `~/.claude/` are symlinks. Changing them is an atomic filesystem operation — no copying, no rewriting.

Claude Desktop uses real directory renames instead of symlinks (Electron doesn't follow symlinks for its data directory). On switch, csw renames `Claude/` → `Claude.<from>/` and `Claude.<to>/` → `Claude/`.

## Development

```bash
git clone https://github.com/mtxr/claude-switch
cd claude-switch

# Debug build (fast compile, leak detection)
zig build

# Optimised builds
zig build -Doptimize=ReleaseSafe   # bounds checks on, ~670 KB
zig build -Doptimize=ReleaseSmall  # smallest binary
zig build -Doptimize=ReleaseFast   # max speed

# Run tests
zig build test
```

CI runs on every push: `zig build` (debug) and `zig build test`.

Releases are built automatically when a tag is pushed:

```bash
git tag v0.2.0
git push origin --tags
```

GitHub Actions cross-compiles arm64 and x86_64 binaries (`-Doptimize=ReleaseSmall`) and publishes them to the release.

## License

MIT — see [LICENSE](LICENSE).
