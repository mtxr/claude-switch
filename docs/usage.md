# Usage

```
csw save [name]      Save the current Claude Code session as a named profile
csw use [name]       Switch Claude Code to a saved profile
csw rename [old] <new>  Rename a profile, its login and (with --desktop/--all) its Desktop data
csw new <name>       Create a new empty profile slot
csw delete [name]    Delete a profile
csw list             List all saved profiles
csw whoami           Show active session info
csw pick             Interactive profile picker (sk, fzf or built-in)
csw update [--edge] [--verbose]  Update csw to the latest release (--edge: latest edge build)
csw logout-all       Log out and remove all active symlinks
csw run [name] [-- args]  Run claude with a profile in this terminal only
csw login [name]     Start claude for a profile and log in once
csw env [name]       Print `export CLAUDE_CONFIG_DIR=...` for a profile
csw bind [name]      Bind the current directory to a profile (.csw)
csw unbind           Remove the .csw binding from the current directory
csw hook <shell>     Print the shell hook with completions (zsh|bash|fish)
csw completion <shell>  Print only the shell completions (zsh|bash|fish)
csw man            Print the man page (roff) to stdout
csw doctor           Check that everything csw needs is in order
```

Commands written with `[name]` open the picker (sk, then fzf, then a built-in numbered list) when the name is omitted in a terminal. The built-in list accepts a number, a profile name or part of a name; an ambiguous part narrows the list, and an empty line cancels. Without a terminal they print a usage error. Cancelling the picker exits without doing anything. `new` always needs a name, since it creates one. `save` without a name lets you pick an existing profile to overwrite. `rename` with a single name picks the old profile and uses that name as the new one.

## Claude Code and Claude Desktop

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

## Commands in detail

- **`save [name]`** — Stores the profile's login and migrates `~/.claude.json` and `~/.claude/` to profile paths if they are not managed yet. The login kept is the freshest of the profile's stored login and, for the active profile, the live one.
- **`use [name]`** — Auto-saves the current profile first, copies the target's login to the live Claude Code entry and re-points `~/.claude.json` and `~/.claude/` at the profile.
- **`new <name>`** — Creates `~/.claude.<name>.json` and `~/.claude.<name>/`, saves the active profile's login first, clears the live login and activates the new profile. Log in with `csw login <name>`, then `csw save <name>`.
- **`rename [old] <new>`** — Renames the profile files, re-links the active symlinks and the inner config link, and moves the per-directory Keychain entry. All preconditions are checked before anything changes, and a failure part-way rolls back. It cannot update `.csw` files that name the old profile or running shells whose `CLAUDE_CONFIG_DIR` still points at the old directory, so it tells you to.
- **`delete [name]`** — Removes the profile files and its stored logins. If the profile is active, the live login and the symlinks go too.
- **`list`** — Lists profiles; `◀` marks the active one.
- **`whoami`** — Shows the active Claude Code session, the Desktop owner and session, and saved profiles with email, plan and token expiry.
- **`pick`** — `use` through the picker.
- **`logout-all`** — Removes the live Claude Code login and the `~/.claude.json` / `~/.claude/` symlinks. Profile files and their stored logins are kept.
- **`update [--edge] [--verbose]`** — Downloads the latest release binary from GitHub, checks it against the release `SHA256SUMS` and replaces the current one atomically. It refuses, leaving the installed binary untouched, when the checksums are missing, do not list the asset or do not match. When csw was installed by Homebrew, Nix or a system package it does not replace itself and prints the package manager command instead. With `--edge` it installs the latest edge build instead (see [Edge channel](install.md#edge-channel)).
- **`doctor`** — See [Doctor](troubleshooting.md#doctor).
