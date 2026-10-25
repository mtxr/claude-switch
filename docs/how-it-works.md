# How it works

## What csw writes

| What | Where |
|---|---|
| Profile config | `~/.claude.<profile>.json` and `~/.claude.<profile>/` |
| Active Code profile | `~/.claude.json` and `~/.claude/` as symlinks to the active profile |
| Per-directory binding | `.csw` in each directory you `csw bind` |
| Desktop owner marker | `~/Library/Application Support/Claude/.csw-profile` |
| Desktop data of a profile | `~/Library/Application Support/Claude.<profile>/` (a swapped-out data dir) |
| Profile logins (macOS) | Keychain, one entry per profile (see below) |
| Update check cache | `/tmp/csw-update-cache` |

## Credentials

On macOS, Claude Code logins live in the Keychain, never in a csw file. csw writes them through `security -i` over stdin, so a secret never appears in process arguments:

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

Switching Claude Code is instant: `~/.claude.json` and `~/.claude/` are symlinks, so changing them is an atomic filesystem operation with no copying.

Claude Desktop uses real directory renames instead (Electron does not follow symlinks for its data directory). On a swap, csw renames `Claude/` to `Claude.<from>/` and `Claude.<to>/` to `Claude/`. Desktop is force-quit with `pkill -9` and reopened only if the target profile has Desktop data.
