# How it works

## What csw writes

| What | Where |
|---|---|
| Profile | `~/.claude.<profile>/`, a directory that holds the profile's own `.claude.json` |
| Active Code profile | `~/.claude` as a symlink to the profile directory, and `~/.claude.json` as a symlink to `.claude/.claude.json` |
| Per-directory binding | `.csw` in each directory you `csw bind` |
| Desktop owner marker | `~/Library/Application Support/Claude/.csw-profile` |
| Desktop data of a profile | `~/Library/Application Support/Claude.<profile>/` (a swapped-out data dir) |
| Profile logins (macOS) | Keychain, one entry per profile (see below) |
| Update check cache | `/tmp/csw-update-cache` |

## Credentials

On macOS, Claude Code logins live in the Keychain, never in a csw file. csw writes them through `security -i` over stdin, so a secret does not appear in process arguments. Logins longer than about 4000 bytes do not fit through `security -i`; those are passed to `security add-generic-password -X` as hex, the same fallback Claude Code uses for its own large entries:

| Keychain service | Purpose |
|---|---|
| `Claude Code-credentials-<hash>` | The profile's login. This is the entry Claude Code itself uses for `CLAUDE_CONFIG_DIR=~/.claude.<profile>`; `<hash>` is the first 8 hex characters of the SHA-256 of that directory path. |
| `Claude Code-credentials` | The live login Claude Code reads when `CLAUDE_CONFIG_DIR` is not set. Managed by Claude; `csw use` copies the profile login here. |
| `csw-code-<profile>` | Legacy entry from older versions. Converted to the per-directory entry and deleted the first time the profile is used or saved, keeping whichever token expires last. |
| `Claude Safe Storage` | Claude Desktop's own encryption key. csw only reads it to show the Desktop session in `whoami` and `doctor`. |

`save` and the auto-save inside `use` keep the freshest token between the profile's entry and, for the active profile, the live entry, so a token Claude refreshed is not lost. `new` does the same for the active profile before clearing the live entry.

Claude Desktop's session is an Electron cookie, encrypted by Desktop itself. csw never copies it; it only moves whole data directories.

## Network

csw does not send credentials anywhere. It makes network requests only to GitHub: `csw update` and `install.sh` download releases, and most commands start a background check for a newer release at most once every 24 hours (it queries the GitHub releases API with `curl` and caches the result in `/tmp/csw-update-cache`). The check is skipped by `update`, `env`, `hook`, `completion`, `man` and the internal `_profiles` command.

## Profile switching

Switching Claude Code is instant: `~/.claude` is a symlink to the profile directory and `~/.claude.json` follows it through `.claude/.claude.json`, so a switch changes one symlink atomically, with no copying.

### Where the config lives

Everything a profile owns is inside `~/.claude.<profile>/`, including `.claude.json`. That is exactly where Claude Code looks when `CLAUDE_CONFIG_DIR` points at the directory (the hook, `csw run` and `csw env` all do), so nothing has to be linked there and nothing breaks when Claude Code rewrites the file.

`~/.claude` and `~/.claude.json` only matter for programs that start without `CLAUDE_CONFIG_DIR`. Claude Code replaces `~/.claude.json` with a regular file when it saves it, which detaches it from the profile. csw puts the link back on its next command: the newer content is kept in the profile, and the other version is saved next to it as `.claude.json.csw-bak`.

### Upgrading from the old layout

Versions up to 1.2 kept the config next to the directory as `~/.claude.<profile>.json` and linked into it. The first csw command after the upgrade moves each file into its directory, and the shell hook does it for the profile it uses. It prints one line when it moved something and does nothing afterwards. If both a loose file and a `.claude.json` inside already exist, the newer one is kept and the other is saved as `.claude.json.csw-bak`. Going back to an older csw does not see profiles in the new layout; move each `~/.claude.<profile>/.claude.json` out to `~/.claude.<profile>.json` first.

Claude Desktop uses real directory renames instead (Electron does not follow symlinks for its data directory). On a swap, csw renames `Claude/` to `Claude.<from>/` and `Claude.<to>/` to `Claude/`. Desktop is force-quit with `pkill -9` and reopened only if the target profile has Desktop data.
