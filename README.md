# claude-switch

[![Release](https://img.shields.io/github/v/release/mtxr/claude-switch)](https://github.com/mtxr/claude-switch/releases)
[![CI](https://github.com/mtxr/claude-switch/actions/workflows/ci.yml/badge.svg)](https://github.com/mtxr/claude-switch/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Switch between Claude Code and Claude Desktop accounts without logging out.** `csw` keeps one profile per account, lets several terminals use different accounts at the same time, and picks the account from the directory you are in.

<!-- demo: add terminal recordings (GIFs) here -->

## Why csw

Several tools solve the "one machine, several Claude Code accounts" problem. These are the places where csw is ahead of the closest ones (see the [comparison](#comparison)):

- **Claude Desktop and Claude Code switch together.** None of the others document Desktop support. `csw use work --all` moves both.
- **Nothing to install first.** One static binary of about 400 KB. No Node.js, no `gum`, no wrapper script on your `PATH`, no local proxy.
- **Claude Code stays in charge of its own login.** csw does not shim or wrap `claude`. Each profile's token lives in the same Keychain entry Claude Code uses for that config directory.
- **Projects pick their account.** A `.csw` file plus the shell hook switches profiles on `cd`, with completions for zsh, bash and fish, a man page and a picker that needs no `fzf`.
- **You can verify what you install.** Every release ships `SHA256SUMS` and build provenance attestations, and both the installer and `csw update` check the checksum before replacing anything.
- **`csw doctor` explains what is wrong** instead of leaving you to read config directories by hand.

## Install

```bash
brew install mtxr/tap/csw
```

```bash
curl -fsSL https://raw.githubusercontent.com/mtxr/claude-switch/main/install.sh | bash
```

Nix, deb, rpm, mise, manual downloads, the edge channel and checksum verification are in [docs/install.md](docs/install.md). macOS and Linux are supported; on Windows use WSL.

## Quick start

```bash
csw save work           # store the account you are logged into now
csw new personal        # create a second profile, logged out
csw login personal      # run /login inside claude once
csw save personal

csw use work            # switch every terminal
csw use personal --all  # switch Claude Code and Claude Desktop together
csw run work            # run claude as "work" in this terminal only
cd ~/work/project && csw bind work   # this directory always uses "work"
```

Add `eval "$(csw hook zsh)"` to `~/.zshrc` (bash and fish are supported too) for per-directory switching and completions.

## Features

| | |
|---|---|
| **Profiles** | `save`, `use`, `new`, `rename`, `delete`, `list`, `pick`. See [usage](docs/usage.md). |
| **Claude Desktop** | `--desktop` and `--all` move Desktop together with Claude Code. See [usage](docs/usage.md#claude-code-and-claude-desktop). |
| **Several terminals** | `run`, `login` and `env` use a profile in one terminal only. See [profiles](docs/profiles.md). |
| **Per directory** | `.csw` plus the shell hook. See [profiles](docs/profiles.md#per-directory-profiles). |
| **Diagnostics** | `csw doctor` checks everything csw needs. See [troubleshooting](docs/troubleshooting.md#doctor). |
| **Updates** | `csw update` verifies the checksum before replacing the binary. |

## Comparison

The table is based on what each project's README documents as of 2026-10-24. ✅ means documented, ➖ means the README does not mention it (not that it is missing). Corrections are welcome.

| | csw | [claude-switch](https://github.com/SaschaHeyer/claude-switch) | [Cloak](https://github.com/synth1s/cloak) | [claudectx](https://github.com/foxj77/claudectx) | [claude-account](https://github.com/hamzarehmandeveloper/claude-account) | [swapdex](https://github.com/youdie006/swapdex) |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Language | ⚡ Zig | 🐚 Bash | 🟩 Node.js | 🐹 Go | 🦀 Rust | 🦀 Rust |
| Single static binary | ✅ | ➖ needs `gum` | ➖ needs Node 20+ | ✅ | ✅ | ✅ |
| Separate config per profile | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Switchable default profile | ✅ | ➖ | ➖ | ✅ | ➖ | ➖ |
| Concurrent terminals | ✅ | ✅ | ✅ | ✅ `run` | ✅ | ✅ |
| Per-directory binding | ✅ `.csw` + hook | ➖ | ✅ `bind` | ➖ | ➖ | ➖ |
| Claude Desktop | ✅ | ➖ | ➖ | ➖ | ➖ | ➖ |
| Shell completions | ✅ zsh, bash, fish | ➖ | ➖ | ✅ bash, zsh, fish | ➖ | ➖ |
| Man page | ✅ | ➖ | ➖ | ➖ | ➖ | ➖ |
| Diagnostics (`doctor`) | ✅ | ➖ | ➖ | ➖ | ➖ | ✅ |
| Rename a profile | ✅ | ➖ | ✅ | ➖ | ➖ | ➖ |
| No wrapper, shim or proxy | ✅ | ✅ | ✅ | ✅ | ➖ wrapper | ➖ shim + proxy |
| Checksum-verified install and update | ✅ | ➖ | ➖ | ➖ | ✅ checksums | ➖ |
| Build provenance attestations | ✅ | ➖ | ➖ | ➖ | ➖ | ➖ |
| macOS | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Linux | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Windows | ➖ WSL | ➖ | ✅ | ✅ | ➖ | ➖ |

Where the others go further: claudectx also manages API providers, MCP servers and `CLAUDE.md` per profile and runs on Windows. claude-switch (SaschaHeyer) shares skills and plugins across profiles and syncs sessions. swapdex covers several CLIs and reports usage and quota. csw stays focused on switching accounts safely.

Other projects worth a look, not evaluated here: [clauth](https://crates.io/crates/clauth), [ccsw](https://crates.io/crates/ccsw), [claude-account-switch](https://github.com/ftery0/claude-account-switch) and [ccswitch](https://github.com/binoyPeries/ccswitch).

## Documentation

- [Install](docs/install.md)
- [Usage](docs/usage.md)
- [Profiles in several terminals and directories](docs/profiles.md)
- [How it works](docs/how-it-works.md)
- [Troubleshooting, Linux and known limitations](docs/troubleshooting.md)
- [Migrating](docs/migrating.md)
- [Development](docs/development.md)

## License

MIT — see [LICENSE](LICENSE).
