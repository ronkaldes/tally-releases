# Tally for Mac: releases

This repository holds the downloads for [Tally](https://www.tallyless.com), the Mac app that shows what your AI tools cost. It has no source code. Each release has two files:

- `Tally-<version>.dmg`: the app, for example `Tally-2.3.1.dmg`.
- `SHA256SUMS`: the checksum of the app file.

## Install

1. Open the [latest release](https://github.com/ronkaldes/tally-releases/releases/latest) and download `Tally-<version>.dmg` and `SHA256SUMS`.
2. Check the file. In Terminal, in the folder you downloaded to: `shasum -a 256 -c SHA256SUMS`. It must say `OK`.
3. Open the DMG and drag Tally to Applications.
4. The app is not notarized yet, so macOS asks you to approve it the first time: open it once, then go to System Settings > Privacy & Security and choose **Open Anyway**.

Betas are marked "Pre-release" on the releases page. The latest stable release never points at a beta.

## Install from Terminal

`install-mac.sh` in this repository does steps 1 to 4 for you: it downloads the latest stable release with plain `curl`, refuses to continue unless the checksum matches, copies Tally to Applications and opens it. Read it first, then run it:

```bash
curl -fsSLO https://raw.githubusercontent.com/ronkaldes/tally-releases/main/install-mac.sh
less install-mac.sh
bash install-mac.sh
```

Options: `--version 2.3.1` for a specific release and `--dry-run` to download and check without installing. The comment at the top of the script lists the rest.

## Updates

Tally 2.3.2 and later check this repository for new stable releases. Earlier versions check an older location, so install a newer version by hand once.
