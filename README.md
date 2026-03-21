# claude-switch

Swap between Claude accounts (Code + Desktop) on macOS with a single command.

**Fully offline. Zero storage.** No tokens are sent anywhere and nothing is written to disk by csw. All credentials live exclusively in macOS Keychain — the same encrypted, hardware-backed store that Claude itself uses. No config files, no dotfiles, no plaintext secrets.

## Requirements

- macOS
- [uv](https://astral.sh/uv)
- `sk` or `fzf` for the interactive picker

```bash
brew install uv sk
```

## Install

```bash
git clone https://github.com/mtxr/claude-switch ~/work/claude-switch
cd ~/work/claude-switch
./install.sh
```

This installs a `csw` wrapper to `~/.local/bin` pointing to `claude_switch.py` in the repo.

## Getting started

You need to save each account as a profile before you can switch between them.
Do this once per account:

**1. Save your current account (e.g. work)**

```bash
csw save work
```

This saves the session tokens into macOS Keychain and migrates `~/.claude.json` and `~/.claude/` to profile-specific paths (`~/.claude.work.json`, `~/.claude.work/`), leaving symlinks in place. From now on, switching just swaps the symlinks.

If you run `csw list` or `csw new` before saving, csw will detect your unmanaged profile and offer to save it for you.

**2. Create a slot for the second account and log in**

```bash
csw new personal   # creates ~/.claude.personal.json + ~/.claude.personal/, activates symlinks
claude auth login   # logs in as the personal account into the active slot
```

**3. Save the second account**

```bash
csw save personal
```

You're set. From now on, switch between accounts instantly:

```bash
csw switch work
csw switch personal
# or interactively:
csw pick
```

## Usage

```bash
# Save current sessions (Code + Desktop) as a named profile
csw save work
csw save personal

# Interactive picker (sk / fzf)
csw pick

# Switch directly
csw switch work

# Show active session info + saved profiles
csw whoami

# List profiles
csw list

# Delete a profile
csw delete personal

# Create a new empty profile slot
csw new work2

# Log out of all accounts and remove symlinks
csw logout-all

# Pull latest version from git
csw update
```

To run locally without installing:

```bash
uv run --with pycryptodome claude_switch.py <command>
```

## How it works

### Security model

csw does not create any files or directories of its own. All session tokens are stored in **macOS Keychain**, protected by the same OS-level encryption and access controls that guard your passwords, SSH keys, and certificates.

| Data | Where it lives |
|---|---|
| Claude Code tokens | Keychain: `csw-code-<profile>` |
| Claude Desktop tokens | Keychain: `csw-desktop-<profile>` |
| Active Code session | Keychain: `Claude Code-credentials` (managed by Claude) |
| Active Desktop session | Electron SQLite cookie, AES encrypted (managed by Claude) |
| Profile configs | `~/.claude.<profile>.json` + `~/.claude.<profile>/` (symlinked from `~/.claude.json` and `~/.claude/`) |

- No network requests are made at any point.
- No plaintext tokens ever touch the filesystem.
- Both Claude Code and Claude Desktop are optional — csw works with either or both.
- On switch, Claude Desktop is quit automatically and relaunched.

## Files

```
claude-switch/
├── claude_switch.py   # all the logic
├── install.sh         # installs wrapper to ~/.local/bin
└── README.md
```

## Development

```bash
brew install lefthook
lefthook install
```

This sets up a pre-commit hook that runs `ruff` (lint + format check) on every commit.

## License

MIT — see [LICENSE](LICENSE).
