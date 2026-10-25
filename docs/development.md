# Development

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

CI runs `zig build`, a release build and `zig build test` on macOS and Ubuntu for every push and pull request, and installs the packages on several Linux distributions.

Releases are drafted by [release-please](https://github.com/googleapis/release-please) and published only after every asset is built and verified. See [RELEASING.md](../RELEASING.md).
