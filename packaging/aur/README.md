# AUR package

`PKGBUILD` is a template for the `claude-switch-bin` AUR package. It installs the prebuilt static musl release binary, so it works on x86_64 and aarch64.

Publishing is manual:

1. Render the template for a released version, using that release's `SHA256SUMS`:

   ```bash
   gh release download v1.0.0 --repo mtxr/claude-switch --pattern SHA256SUMS
   packaging/render.sh aur 1.0.0 SHA256SUMS > PKGBUILD
   ```

2. Clone `ssh://aur@aur.archlinux.org/claude-switch-bin.git`, copy the rendered `PKGBUILD` in, run `makepkg --printsrcinfo > .SRCINFO`, commit and push.

The license file is fetched from the tagged source and is the only entry with a `SKIP` checksum.
