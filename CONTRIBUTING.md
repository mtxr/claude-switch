# Contributing

Build, test and demo details live in [docs/development.md](docs/development.md).

## Setup

`csw` is written in Zig 0.17.0.

```bash
zig build
zig build test
zig fmt src build.zig
```

Tests that touch the real macOS Keychain are opt-in with `CSW_TEST_KEYCHAIN=1`.

## Pull requests

- Use [Conventional Commits](https://www.conventionalcommits.org/) for commit messages and PR titles (`feat:`, `fix:`, `docs:`, `chore:`). [release-please](https://github.com/googleapis/release-please) builds the changelog and releases from them. See [RELEASING.md](RELEASING.md).
- Write everything in English: code, comments, tests, docs, commit messages and PR text.
- Keep changes focused, run `zig fmt` and make sure `zig build test` passes.

To report a vulnerability, follow [SECURITY.md](SECURITY.md) instead of opening an issue.
