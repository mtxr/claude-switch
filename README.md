# claude-switch

`csw` switches between Claude Code accounts (and, on macOS, Claude Desktop accounts) with a single command. It also lets several terminals use different accounts at the same time, and can pick the account from the directory you are in.

<!-- demo: add terminal recordings (GIFs) here -->

## Install

### Option 1 — download binary (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/mtxr/claude-switch/main/install.sh | bash
```

This downloads the latest release binary for your OS and architecture (macOS or Linux, arm64 or x86_64) to `~/.local/bin/csw` and creates a `claude-switch` alias next to it.

### Option 2 — build from source

Requires [Zig 0.17.0](https://ziglang.org/download/) (or install via [mise](https://mise.jdx.dev): `mise use zig@0.17.0`).

```bash
git clone https://github.com/mtxr/claude-switch
cd claude-switch
zig build -Doptimize=ReleaseSmall
cp zig-out/bin/csw ~/.local/bin/csw
```

### Option 3 — manual download

Grab the binary for your platform from [Releases](https://github.com/mtxr/claude-switch/releases), put it somewhere in your `$PATH`, and `chmod +x` it.

### Verifying a download

Every release ships a `SHA256SUMS` file, and each binary and `SHA256SUMS` carry a GitHub build provenance attestation. `install.sh` checks the checksum before installing and refuses to install on a mismatch. To verify a manual download:

```bash
shasum -a 256 -c SHA256SUMS --ignore-missing
gh attestation verify csw-aarch64-apple-darwin --repo mtxr/claude-switch
```

---

Make sure `~/.local/bin` is in your `$PATH` (add to `~/.zshrc` if needed):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

The interactive picker needs [sk](https://github.com/lotabout/skim) or [fzf](https://github.com/junegunn/fzf):

```bash
brew install sk
```

## Migrating from the Python version

Profiles saved by the previous Python-based `csw` keep working. Its `csw-code-<profile>` Keychain entries are converted automatically the first time each profile is used or saved (see [Credentials](#credentials)).

1. Remove the old wrapper: `rm ~/.local/bin/csw ~/.local/bin/claude-switch`
2. Install the new binary (see above).
3. Check that your profiles are still there: `csw whoami` and `csw list`.

`csw update` downloads the latest release binary from GitHub Releases instead of running `git pull`.

## Getting started

Save each account as a profile once.

**1. Save your current account (for example, work)**

```bash
csw save work
```

This stores the login and migrates `~/.claude.json` and `~/.claude/` to profile-specific paths (`~/.claude.work.json`, `~/.claude.work/`), leaving symlinks in place.

**2. Create a slot for a second account and log in**

```bash
csw new personal    # creates the profile and activates it, logged out
csw login personal  # starts claude for that profile; run /login inside it
```

**3. Save the second account**

```bash
csw save personal
```

**4. Switch**

```bash
csw use work
csw use personal
csw pick            # or pick interactively
```

## Usage

```
csw save [name]      Save the current Claude Code session as a named profile
csw use [name]       Switch Claude Code to a saved profile
csw rename [old] <new>  Rename a profile, its login and (with --desktop/--all) its Desktop data
csw new <name>       Create a new empty profile slot
csw delete [name]    Delete a profile
csw list             List all saved profiles
csw whoami           Show active session info
csw pick             Interactive profile picker (sk / fzf)
csw update [--verbose]  Update csw to the latest release
csw logout-all       Log out and remove all active symlinks
csw run [name] [-- args]  Run claude with a profile in this terminal only
csw login [name]     Start claude for a profile and log in once
csw env [name]       Print `export CLAUDE_CONFIG_DIR=...` for a profile
csw bind [name]      Bind the current directory to a profile (.csw)
csw unbind           Remove the .csw binding from the current directory
csw hook <shell>     Print the shell hook with completions (zsh|bash)
csw completion <shell>  Print only the shell completions (zsh|bash)
csw doctor           Check that everything csw needs is in order
```

Commands written with `[name]` open the picker (sk, then fzf) when the name is omitted in a terminal. Without a terminal they print a usage error. Cancelling the picker exits without doing anything. `new` always needs a name, since it creates one. `save` without a name lets you pick an existing profile to overwrite. `rename` with a single name picks the old profile and uses that name as the new one.

### Claude Code and Claude Desktop

Claude Code and Claude Desktop keep independent state, so a profile can be on one account in Claude Code and another in Claude Desktop. Claude Desktop is macOS-only.

`save`, `use`, `rename`, `new`, `delete`, `list`, `pick` and `logout-all` take a product flag:

| Flag | Acts on |
|---|---|
| none | Claude Code only |
| `--desktop` | Claude Desktop only |
| `--all` | Claude Code and Claude Desktop together |

| Command | Desktop effect |
|---|---|
| `csw save <name> --desktop` | Assigns the Desktop data dir to the profile, if it has no owner yet. |
| `csw use <name> --desktop` | Force-quits Desktop, swaps the data dirs and reopens it if the profile has Desktop data. Claude Code stays where it is. |
| `csw rename <old> <new> --desktop` | Renames `Claude.<old>/` and updates the owner marker. Desktop is never quit. |
| `csw new <name> --desktop` | Creates the profile and swaps Desktop to an empty data dir so you can log in. |
| `csw delete <name> --desktop` | Removes `Claude.<name>/` and clears the owner marker if it was that profile. Without the flag, Desktop data is kept. |
| `csw list --desktop` | Marks only the Desktop profile (`--all` marks `◀ code` and `◀ desktop`). |
| `csw pick --desktop` | `use --desktop` for the chosen profile. |
| `csw logout-all --desktop` | Force-quits Desktop and removes the legacy Desktop symlink. |

`csw whoami` and `csw doctor` are read-only and always report both products.

csw records which profile owns the main Desktop data dir (`~/Library/Application Support/Claude/`) in `Claude/.csw-profile`. The marker travels with the directory when it is renamed. Installs that predate the marker are assigned to the active Code profile the first time `use` or `new` runs.

### Commands in detail

- **`save [name]`** — Stores the profile's login and migrates `~/.claude.json` and `~/.claude/` to profile paths if they are not managed yet. The login kept is the freshest of the profile's stored login and, for the active profile, the live one.
- **`use [name]`** — Auto-saves the current profile first, copies the target's login to the live Claude Code entry and re-points `~/.claude.json` and `~/.claude/` at the profile.
- **`new <name>`** — Creates `~/.claude.<name>.json` and `~/.claude.<name>/`, saves the active profile's login first, clears the live login and activates the new profile. Log in with `csw login <name>`, then `csw save <name>`.
- **`rename [old] <new>`** — Renames the profile files, re-links the active symlinks and the inner config link, and moves the per-directory Keychain entry. All preconditions are checked before anything changes, and a failure part-way rolls back. It cannot update `.csw` files that name the old profile or running shells whose `CLAUDE_CONFIG_DIR` still points at the old directory, so it tells you to.
- **`delete [name]`** — Removes the profile files and its stored logins. If the profile is active, the live login and the symlinks go too.
- **`list`** — Lists profiles; `◀` marks the active one.
- **`whoami`** — Shows the active Claude Code session, the Desktop owner and session, and saved profiles with email, plan and token expiry.
- **`pick`** — `use` through the picker.
- **`logout-all`** — Removes the live Claude Code login and the `~/.claude.json` / `~/.claude/` symlinks. Profile files and their stored logins are kept.
- **`update [--verbose]`** — Downloads the latest release binary from GitHub and replaces the current one.
- **`doctor`** — See [Doctor](#doctor).

## Concurrent profiles

`csw use` changes the account for every terminal. To use different accounts in different terminals at once, csw points `CLAUDE_CONFIG_DIR` at the profile directory, because Claude Code keeps its login per config directory.

- `csw run work [-- <claude args>]` runs `claude` for that profile in this terminal only.
- `csw login work` does the same and reports whether a login is needed.
- `eval "$(csw env work)"` exports `CLAUDE_CONFIG_DIR` in the current shell.

The first time a profile is used this way, csw seeds its Keychain entry from the live login if the profile is the active one and that token has not expired. Otherwise run `/login` inside claude once; Claude Code remembers it for that profile.

### Per-directory profiles

Bind a directory to a profile and let the shell switch for you:

```sh
cd ~/work/project && csw bind work      # writes .csw containing "work"
eval "$(csw hook zsh)"                  # add to ~/.zshrc (bash: ~/.bashrc)
```

On every prompt the hook finds the nearest `.csw` walking up from the current directory and exports `CLAUDE_CONFIG_DIR=~/.claude.<name>`. With no `.csw`, it exports the active profile (the one set by `csw use`). Leaving a bound tree goes back to the active profile, or unsets what the hook set when there is none. A `CLAUDE_CONFIG_DIR` you exported yourself is never overwritten or removed.

- `.csw` holds one profile name. Only names matching `[A-Za-z0-9._-]` (up to 64 characters) that belong to an existing profile are honoured, so an untrusted repository cannot inject shell through it.
- If `.csw` names a profile that does not exist, the hook falls back to the active profile and prints one warning on stderr. It warns again only when the directory or name changes.
- The first export of a profile in a shell seeds its Keychain entry and reports the result on stderr, so stdout stays safe to `eval`.
- `csw unbind` removes the `.csw` in the current directory.

### Shell completions

`eval "$(csw hook zsh)"` (or `bash`) also registers completions, so no extra file or `fpath` change is needed. If you only want completions, use `csw completion zsh` or `csw completion bash`; for zsh you can also save the output as `_csw` in a directory on your `fpath`. Completions cover commands, the flags valid for each command, saved profile names and shell names, and are generated from the same command table as `--help`.

## Doctor

`csw doctor` is read-only and prints `[ok]`, `[warn]` and `[fail]` lines in sections:

- **Claude Code** — whether a login is present.
- **Claude Desktop** (macOS) — `Claude.app`, the process, `Claude Safe Storage`, the data dir, the cookies DB and the session cookie.
- **Profiles** — active and saved profiles, the Desktop owner, profile json without a directory, orphan directories, an inner `.claude.json` that became a regular file, profiles without a stored login, leftover legacy `csw-code-*` entries (macOS), and a profile whose login sits in both the live entry and its per-directory entry.
- **Shell** — what `CLAUDE_CONFIG_DIR` points at, the `.csw` that applies here, and whether the hook is loaded. The hook is reported as "not detected (optional)" unless a `.csw` applies and the hook is clearly missing.
- **Tools** — whether `sk` or `fzf` is installed.

Only the macOS Desktop checks can produce `[fail]` (missing app, missing key, data dir or cookies DB). A `[fail]` makes the command exit non-zero; warnings never do.

## How it works

### What csw writes

| What | Where |
|---|---|
| Profile config | `~/.claude.<profile>.json` and `~/.claude.<profile>/` |
| Active Code profile | `~/.claude.json` and `~/.claude/` as symlinks to the active profile |
| Per-directory binding | `.csw` in each directory you `csw bind` |
| Desktop owner marker | `~/Library/Application Support/Claude/.csw-profile` |
| Desktop data of a profile | `~/Library/Application Support/Claude.<profile>/` (a swapped-out data dir) |
| Profile logins (macOS) | Keychain, one entry per profile (see below) |
| Update check cache | `/tmp/csw-update-cache` |

### Credentials

On macOS, Claude Code logins live in the Keychain, never in a csw file:

| Keychain service | Purpose |
|---|---|
| `Claude Code-credentials-<hash>` | The profile's login. This is the entry Claude Code itself uses for `CLAUDE_CONFIG_DIR=~/.claude.<profile>`; `<hash>` is the first 8 hex characters of the SHA-256 of that directory path. |
| `Claude Code-credentials` | The live login Claude Code reads when `CLAUDE_CONFIG_DIR` is not set. Managed by Claude; `csw use` copies the profile login here. |
| `csw-code-<profile>` | Legacy entry from older versions. Converted to the per-directory entry and deleted the first time the profile is used or saved, keeping whichever token expires last. |
| `Claude Safe Storage` | Claude Desktop's own encryption key. csw only reads it to show the Desktop session in `whoami` and `doctor`. |

`save` and the auto-save inside `use` keep the freshest token between the profile's entry and, for the active profile, the live entry, so a token Claude refreshed is not lost. `new` does the same for the active profile before clearing the live entry.

Claude Desktop's session is an Electron cookie, encrypted by Desktop itself. csw never copies it; it only moves whole data directories.

### Network

csw does not send credentials anywhere. It makes network requests only to GitHub: `csw update` and `install.sh` download releases, and most commands start a background check for a newer release at most once every 24 hours (it queries the GitHub releases API with `curl` and caches the result in `/tmp/csw-update-cache`). The check is skipped by `update`, `env`, `hook`, `completion` and the internal `_profiles` command.

### Profile switching

Switching Claude Code is instant: `~/.claude.json` and `~/.claude/` are symlinks, so changing them is an atomic filesystem operation with no copying.

Claude Desktop uses real directory renames instead (Electron does not follow symlinks for its data directory). On a swap, csw renames `Claude/` to `Claude.<from>/` and `Claude.<to>/` to `Claude/`. Desktop is force-quit with `pkill -9` and reopened only if the target profile has Desktop data.

## Linux

`csw` builds and runs on Linux (x86_64 and aarch64; `install.sh` and `csw update` pick the `unknown-linux-musl` asset). Supported: `save`, `use`, `rename`, `new`, `delete`, `list`, `pick`, `whoami` (Claude Code), `logout-all`, `run`, `login`, `env`, `bind`, `unbind`, `hook`, `completion`, `doctor`.

On Linux, Claude Code keeps its credentials in `<config dir>/.credentials.json` (mode 0600). Because `~/.claude/` is a symlink to the active profile directory, credentials switch together with the profile, and with `CLAUDE_CONFIG_DIR` each profile directory carries its own. csw does not copy them into another store. Claude Desktop and Keychain features are macOS-only and report "not supported" on Linux.

## Known limitations

- **One login, two modes.** If the same profile is used through `CLAUDE_CONFIG_DIR` (hook, `run`) and through the live entry (`csw use` in another shell) at the same time, the two copies of its login can drift and one refresh token may be invalidated. `csw doctor` warns when a profile's login is in both places. Prefer one mode per profile at a time.
- **Token on the command line.** csw writes Keychain entries through the macOS `security` tool, so the secret is briefly visible in that process's arguments to other processes of the same user.
- **Desktop is force-quit.** `--desktop` and `--all` end Claude Desktop with `pkill -9` before swapping, so unsaved state in Desktop is lost.
- **Two Desktops at once is not supported.** A second Desktop instance on its own data dir (an `--isolated` mode) is not implemented.
- **Inner config link.** csw links `~/.claude.<name>/.claude.json` to `~/.claude.<name>.json`. If Claude Code rewrites that file atomically, the link can become a regular file; `csw doctor` reports it.
- **Editors.** IDE extensions may ignore `CLAUDE_CONFIG_DIR`.
- **`.csw` and `rename`.** Renaming a profile does not edit `.csw` files that name it or already-running shells.

## Development

```bash
git clone https://github.com/mtxr/claude-switch
cd claude-switch

zig build                          # debug build
zig build -Doptimize=ReleaseSmall  # smallest binary
zig build test                     # unit tests
```

The tests that touch the real macOS Keychain are skipped unless you opt in:

```bash
CSW_TEST_KEYCHAIN=1 zig build test
```

They only create and delete entries named `csw-test-*` and entries keyed to temporary paths; they never modify your real logins.

CI runs `zig build`, a release build and `zig build test` on macOS and Ubuntu for every push and pull request.

Releases are managed by [release-please](https://github.com/googleapis/release-please): merging its release pull request tags the version, and GitHub Actions cross-compiles the arm64 and x86_64 binaries for macOS and Linux and publishes them to the release.

## License

MIT — see [LICENSE](LICENSE).
