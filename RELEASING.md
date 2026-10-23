# Releasing

## How a release flows

1. Conventional commits land on `main`. Release Please keeps a release PR up to date (version bump in `build.zig.zon` and `src/main.zig`, changelog).
2. Merging the release PR makes Release Please create the tag and a **draft** GitHub release (`draft` and `force-tag-creation` are set in `.github/release-please-config.json`). A draft is never `releases/latest`, so `install.sh` and `csw update` do not see it.
3. `release-assets.yml` builds the four binaries (macOS arm64 and x86_64, Linux musl x86_64 and aarch64), the `.deb` and `.rpm` packages and `SHA256SUMS`, uploads them to the draft and attests each file.
4. `release-finalize.yml` checks that the draft holds every binary, at least one deb and one rpm, `SHA256SUMS`, and that `SHA256SUMS` lists every other asset. Only then it publishes the release (`--latest`, or `--latest=false` for a prerelease).
5. For a stable release it then renders the Homebrew formula from `SHA256SUMS` and pushes it, plus the `claude-switch` alias, to `mtxr/homebrew-tap`. This step is skipped when `HOMEBREW_TAP_TOKEN` is not set and for prereleases.

If any build, package or checksum job fails, the release stays an unpublished draft and `latest` keeps pointing at the previous version.

## Dry run

`release-dry-run.yml` runs the same build, packages and checksums without a release, a tag, attestations or the tap. It uploads the results as workflow artifacts (kept 3 days), then verifies them: `sha256sum -c SHA256SUMS`, the Homebrew formula and PKGBUILD render against the real checksums, the Linux binary passes `packaging/smoke.sh` on Alpine, Debian and Fedora, and the deb and rpm install and remove cleanly.

It runs on every pull request that touches the release workflows, `packaging/`, the release config or the build files. To run it by hand:

```sh
gh workflow run release-dry-run.yml --ref <branch> -f version=0.0.0-dryrun
```

The workflow only has `contents: read`, so it cannot write to a release even by mistake.

## Recovering from a failed release

- A job failed after the draft was created: open the failed run and use **Re-run failed jobs**. Uploads use `--clobber`, so they are safe to repeat.
- The run cannot be re-run, or Release Please did not report a release: run `gh workflow run release-retry.yml -f tag=vX.Y.Z`. It refuses to touch a release that is already published.
- The draft is beyond repair: `gh release delete vX.Y.Z --cleanup-tag --yes`, fix the problem, then run `gh workflow run release-retry.yml` after recreating the release, or revert the release PR commit and let Release Please open a new one.
- A published release turns out to be bad: `gh release edit vX.Y.Z --latest=false` immediately so installers stop picking it, then ship a fixed version.

## Homebrew tap token

`HOMEBREW_TAP_TOKEN` is a fine-grained personal access token limited to `mtxr/homebrew-tap` with `Contents: Read and write`, stored as an Actions secret of this repository. Only the `publish-packages` job reads it. Rotate it before it expires (`gh secret set HOMEBREW_TAP_TOKEN --repo mtxr/claude-switch`).

## What only a real release verifies

- Release Please creating a draft with a tag, and reporting `release_created` and `tag_name` for it.
- `gh release upload`, `download` and `edit` on a draft by tag.
- The attestations (`gh attestation verify <asset> --repo mtxr/claude-switch`).
- The push to the tap.
