# Migrating

## From the Python version

Profiles saved by the previous Python-based `csw` keep working. Its `csw-code-<profile>` Keychain entries are converted automatically the first time each profile is used or saved (see [Credentials](how-it-works.md#credentials)).

1. Remove the old wrapper: `rm ~/.local/bin/csw ~/.local/bin/claude-switch`
2. Install the new binary (see above).
3. Check that your profiles are still there: `csw whoami` and `csw list`.

`csw update` downloads the latest release binary from GitHub Releases, verifies it against the release `SHA256SUMS` and replaces the installed binary atomically, instead of running `git pull`.

## From 0.x to 1.0

Claude Code and Claude Desktop are now independent. `save`, `use`, `rename`, `new`, `delete`, `list`, `pick` and `logout-all` act on Claude Code only unless you pass `--desktop` or `--all`. Before 1.0, Desktop moved together with Claude Code.

- To get the old behaviour, add `--all`: `csw use work --all`.
- The `csw desktop` command and the `--isolated` option were removed.
