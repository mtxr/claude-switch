# Troubleshooting

## Doctor

`csw doctor` is read-only and prints `[ok]`, `[warn]` and `[fail]` lines in sections:

- **Claude Code** — whether a login is present.
- **Claude Desktop** (macOS) — `Claude.app`, the process, `Claude Safe Storage`, the data dir, the cookies DB and the session cookie.
- **Profiles** — active and saved profiles, the Desktop owner, profile json without a directory, orphan directories, an inner `.claude.json` that became a regular file, profiles without a stored login, leftover legacy `csw-code-*` entries (macOS), and a profile whose login sits in both the live entry and its per-directory entry.
- **Shell** — what `CLAUDE_CONFIG_DIR` points at, the `.csw` that applies here, and whether the hook is loaded. The hook is reported as "not detected (optional)" unless a `.csw` applies and the hook is clearly missing.
- **Tools** — which picker is used: `sk`, `fzf` or the built-in one. A missing `sk`/`fzf` is not a problem.

Only the macOS Desktop checks can produce `[fail]` (missing app, missing key, data dir or cookies DB). A `[fail]` makes the command exit non-zero; warnings never do.

## Linux

`csw` builds and runs on Linux (x86_64 and aarch64; `install.sh` and `csw update` pick the `unknown-linux-musl` asset). Supported: `save`, `use`, `rename`, `new`, `delete`, `list`, `pick`, `whoami` (Claude Code), `logout-all`, `run`, `login`, `env`, `bind`, `unbind`, `hook`, `completion`, `man`, `doctor`.

On Linux, Claude Code is expected to keep its credentials in `<config dir>/.credentials.json` (mode 0600). Because `~/.claude/` is a symlink to the active profile directory, credentials switch together with the profile, and with `CLAUDE_CONFIG_DIR` each profile directory carries its own. csw does not copy them into another store. Claude Desktop and Keychain features are macOS-only and report "not supported" on Linux.

## Known limitations

Limits that come from the platform or from Claude Code itself:

- **One login, two modes.** If the same profile is used through `CLAUDE_CONFIG_DIR` (hook, `run`) and through the live entry (`csw use` in another shell) at the same time, the two copies of its login can drift and one refresh token may be invalidated. `csw doctor` warns when a profile's login is in both places. Prefer one mode per profile at a time.
- **Editors.** IDE extensions may ignore `CLAUDE_CONFIG_DIR`, in which case they keep using the active profile.
- **`.csw` and `rename`.** Renaming a profile does not edit `.csw` files that name it or already-running shells, because there is no way to find every `.csw` on disk. `rename` tells you what to update.
- **Desktop quit.** `--desktop` and `--all` ask Claude Desktop to quit, then terminate it and finally kill it if it does not exit, so unsaved state can be lost when Desktop is unresponsive.
- **Credential size.** Keychain values containing line breaks, or longer than about 4000 bytes, are refused instead of being truncated by `security -i`.

- **`csw desktop` login links.** `claude://` links open in the first Claude Desktop that is running, so sign in by copying the code from the browser and pasting it into the window you opened.
