# Synth

A native macOS player and synthesizer for your own MusicXML scores.

Import `.musicxml`, `.xml`, or `.mxl` files into a permanent local library and
hear them played faithfully — repeats and D.C./D.S. expanded, ornaments
realized, with deterministic, adjustable humanization. Assign every line of
the score its own sound: design one in the built-in synthesizer studio, or
download the curated set of openly licensed sampled instruments (3 libraries,
25 instruments, ~3.2 GB) and customize them. Mix lines, save per-piece
presets, and export the result to WAV or AIFF — byte-identical to what
playback renders.

Everything is local: no account, no telemetry, and network access is used
only when you explicitly download instrument libraries.

**Requires macOS 14.0 or newer on Apple Silicon (arm64).**

## Install

1. Download the latest `Synth-X.Y.Z.dmg` from
   [Releases](https://github.com/cedagova/synth/releases) and open it.
2. Drag **Synth.app** into **Applications**.
3. First launch only: these builds are free, ad-hoc-signed distributions
   (not notarized), so macOS blocks the first launch.
   - **macOS 15 (Sequoia) or newer:** open the app once (it will be
     blocked), then go to **System Settings → Privacy & Security**, scroll
     down, and click **"Open Anyway"**.
   - **Older macOS:** right-click Synth.app → **Open** → **Open**.
   - Terminal alternative:
     `xattr -d com.apple.quarantine /Applications/Synth.app`

To verify a download, put `SHA256SUMS.txt` next to the DMG and run
`shasum -a 256 -c SHA256SUMS.txt`.

## Build from source

```sh
xcodebuild build -project Synth.xcodeproj -scheme Synth \
  -configuration Release -destination 'platform=macOS,arch=arm64'
```

Tests: `xcodebuild test` with the same scheme. CI builds and tests every
pull request and push to `main` on Apple Silicon.

## Releasing (maintainer)

Releases are cut on demand — never automatically on merge:

```sh
bin/release 1.2.0
```

That verifies a clean, up-to-date `main`, pushes tag `v1.2.0`, and the
[Release workflow](.github/workflows/release.yml) runs tests, builds the
Release app, ad-hoc signs it, packages a DMG and zip with SHA-256 checksums,
and publishes a GitHub Release with install instructions. The app version is
stamped from the tag.

Upgrading to Developer ID + notarization later (removes the Gatekeeper
step for users) only changes the signing step of that workflow; it requires
an Apple Developer Program membership and certificate secrets.
