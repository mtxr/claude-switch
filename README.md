# claude-switch

Swap between Claude accounts (Code + Desktop) on macOS with a single command.

**Fully offline. Zero storage.** No tokens are sent anywhere and nothing is written to disk by csw. All credentials live exclusively in macOS Keychain — the same encrypted, hardware-backed store that Claude itself uses. No config files, no dotfiles, no plaintext secrets.

## Install

### Option 1 — download binary (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/mtxr/claude-switch/main/install.sh | bash
```

This downloads the latest release binary for your architecture (arm64 or x86_64) to `~/.local/bin/csw`.

### Option 2 — build from source

Requires [Rust](https://rustup.rs).

```bash
git clone https://github.com/mtxr/claude-switch
cd claude-switch
cargo install --path .
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

If you were using the previous Python-based `csw`, your profiles and keychain entries are **fully compatible** — no data migration needed. The Rust binary reads the exact same Keychain entries and file paths.

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
csw save <name>    Save current sessions (Code + Desktop) as a named profile
csw use <name>     Switch to a saved profile
csw new <name>     Create a new empty profile slot (then: claude auth login)
csw delete <name>  Delete a profile and its data
csw list           List all saved profiles
csw whoami         Show active session info (Code + Desktop + saved profiles)
csw pick           Interactive fuzzy picker (sk / fzf)
csw update         Update csw to the latest release
csw logout-all     Log out of all accounts and remove active symlinks
```

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
- Both Claude Code and Claude Desktop are optional — csw works with either or both.
- On switch, Claude Desktop is quit automatically and relaunched.

### Profile switching

Switching profiles is instant because `~/.claude.json` and `~/.claude/` are symlinks. Changing them is an atomic filesystem operation — no copying, no rewriting.

Claude Desktop uses real directory renames instead of symlinks (Electron doesn't follow symlinks for its data directory). On switch, csw renames `Claude/` → `Claude.<from>/` and `Claude.<to>/` → `Claude/`.

## Development

```bash
git clone https://github.com/mtxr/claude-switch
cd claude-switch
cargo build
cargo test
```

CI runs on every push: `cargo clippy` (warnings are errors) and `cargo test`.

Releases are built automatically when a tag is pushed:

```bash
git tag v0.2.0
git push origin --tags
```

GitHub Actions compiles arm64 and x86_64 binaries and publishes them to the release.

## License

MIT — see [LICENSE](LICENSE).
