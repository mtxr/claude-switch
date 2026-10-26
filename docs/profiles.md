# Profiles in several terminals and directories

`csw use` changes the account for every terminal. To use different accounts in different terminals at once, csw points `CLAUDE_CONFIG_DIR` at the profile directory, because Claude Code keeps its login per config directory.

- `csw run work [-- <claude args>]` runs `claude` for that profile in this terminal only.
- `csw login work` does the same and reports whether a login is needed.
- `eval "$(csw env work)"` exports `CLAUDE_CONFIG_DIR` in the current shell.

The first time a profile is used this way, csw seeds its Keychain entry from the live login if the profile is the active one and that token has not expired. Otherwise run `/login` inside claude once; Claude Code remembers it for that profile.

## Claude Desktop for several accounts at once

`csw use <name> --desktop` swaps the single main Claude Desktop between profiles. To keep two Desktops open, run:

```bash
csw desktop work
csw desktop personal
```

Each one is a separate instance started with `--user-data-dir` pointing at that profile's own data directory (`~/Library/Application Support/Claude.<name>`), so it keeps its own login. Nothing is quit, swapped or made active. macOS only.

- The first time for a profile its window is signed out. Sign in there; login links open in your main Desktop, so copy the code from the browser and paste it into the new window.
- The profile that currently owns the main Desktop is refused, because its data lives in the main directory. Open Claude normally, or switch the main Desktop to another profile first.
- While a profile's own Desktop is open, `use --desktop`, `delete --desktop` and `rename --desktop` refuse to touch its data. Quit it first.

## Per-directory profiles

Bind a directory to a profile and let the shell switch for you:

```sh
cd ~/work/project && csw bind work      # writes .csw containing "work"
eval "$(csw hook zsh)"                  # add to ~/.zshrc (bash: ~/.bashrc; fish: csw hook fish | source in config.fish)
```

On every prompt the hook finds the nearest `.csw` walking up from the current directory and exports `CLAUDE_CONFIG_DIR=~/.claude.<name>`. With no `.csw`, it exports the active profile (the one set by `csw use`). Leaving a bound tree goes back to the active profile, or unsets what the hook set when there is none. A `CLAUDE_CONFIG_DIR` you exported yourself is never overwritten or removed.

- `.csw` holds one profile name. Only names matching `[A-Za-z0-9._-]` (up to 64 characters) that belong to an existing profile are honoured, so an untrusted repository cannot inject shell through it.
- If `.csw` names a profile that does not exist, the hook falls back to the active profile and prints one warning on stderr. It warns again only when the directory or name changes.
- The first export of a profile in a shell seeds its Keychain entry and reports the result on stderr, so stdout stays safe to `eval`.
- `csw unbind` removes the `.csw` in the current directory.

## Shell completions

`eval "$(csw hook zsh)"` (or `bash`; in fish, `csw hook fish | source`) also registers completions, so no extra file or `fpath` change is needed. If you only want completions, use `csw completion zsh`, `csw completion bash` or `csw completion fish`; for fish you can also save the output to `~/.config/fish/completions/csw.fish`, and for zsh you can also save the output as `_csw` in a directory on your `fpath`. Completions cover commands, the flags valid for each command, saved profile names and shell names, and are generated from the same command table as `--help`.

## Man page

`csw man` prints a man page generated from the same command table. View it with `csw man | man -l -` (Linux) or `csw man | mandoc | less` (macOS), or save it with `csw man > csw.1`.
