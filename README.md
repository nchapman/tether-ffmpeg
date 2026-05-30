# tether-ffmpeg

Reproducible, **LGPL-only**, **statically linkable** FFmpeg 8.1 builds for every
platform [Tether](https://github.com/nchapman/tether) runs on. CI builds one
artifact per `(os, arch)` and publishes them as GitHub Release assets; both
Tether's CI and developers download the same pinned artifact.

Structurally modeled on [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds)
(pinned versions → per-target build scripts → a CI matrix that publishes
releases), but with two deliberate differences:

1. **LGPL only.** No `--enable-gpl` / `--enable-nonfree`, no `libx264` / `libx265`.
   Tether encodes and decodes exclusively through hardware codecs, every one of
   which is LGPL-compatible: VAAPI (Linux), VideoToolbox (macOS), and
   NVENC / AMF / QSV / Media Foundation (Windows). A consumer that links these
   builds inherits only LGPL obligations, not GPL.
2. **Static libs, MSVC-compatible.** Output is static `lib*.a` / `*.lib` plus
   headers and `lib/pkgconfig/*.pc`, so the final `tether-host` / `tether-client`
   binaries embed FFmpeg and depend only on stable system pieces at runtime
   (libva on Linux, OS frameworks on macOS, Media Foundation on Windows).

## Targets

| OS | Arch | Runner | Hardware codecs enabled |
|----|------|--------|--------------------------|
| linux | x86_64 | `ubuntu-22.04` (builds in an Ubuntu 20.04 container) | VAAPI |
| linux | arm64 | `ubuntu-22.04-arm` (container) | VAAPI |
| macos | arm64 | `macos-14` | VideoToolbox |
| windows | x86_64 | `windows-2022` (MSVC) | NVENC, AMF, QSV (libvpl), Media Foundation, D3D11VA |
| windows | arm64 | `windows-2022` (MSVC cross) | Media Foundation, D3D11VA (no vendor encoders exist on arm64) |

The Linux container is pinned to Ubuntu 20.04 to set a low glibc floor so the
artifacts run on newer distros. macOS x86_64 is a one-line matrix addition if an
Intel-mac target ever returns.

## Versioning

All upstream pins live in [`versions.env`](versions.env) (FFmpeg ref + the
Windows header/dispatcher refs). To cut a release:

1. Bump the relevant ref(s) and `TETHER_FFMPEG_VERSION` in `versions.env`.
2. Commit, then push a tag `vX.Y.Z`.
3. CI builds all targets and publishes a Release with the artifacts + `.sha256` files.

Artifacts are named:

```
tether-ffmpeg-<TETHER_FFMPEG_VERSION>-<os>-<arch>-lgpl-static.tar.xz
```

## Consuming these builds (in the Tether repo)

The link mechanism already exists: `rsmpeg` → `rusty_ffmpeg` → **pkg-config**.
Point pkg-config at an extracted artifact's `lib/pkgconfig` directory. The
Tether repo carries a `mise.local.toml.example`; a developer runs the
`fetch-ffmpeg` step (download + checksum-verify + extract) once and exports:

```toml
# mise.local.toml  (gitignored)
[env]
FFMPEG_PKG_CONFIG_PATH = "/abs/path/to/tether-ffmpeg-<ver>-<os>-<arch>-lgpl-static/lib/pkgconfig"
```

CI does the same fetch and exports the same variable. Same artifact in both
places ⇒ no drift.

## Local builds

Each target builds with one script (CI calls these directly):

```sh
# Linux (inside the container; see docker/Dockerfile.linux)
scripts/build-linux.sh   x86_64    # or arm64

# macOS (native on Apple Silicon; needs `brew install nasm`)
scripts/build-macos.sh   arm64

# Windows (from an MSVC developer prompt with MSYS2 make/nasm on PATH)
scripts/build-windows.ps1 -Arch x86_64   # or arm64
```

Outputs land in `dist/`.

## Status

This is the initial scaffold. The build logic and CI matrix are in place; the
configure flags and version pins still need a first green CI run to validate —
in particular:

- **Windows MSVC + static** is the highest-risk target (FFmpeg `--toolchain=msvc`
  producing `.lib` the Rust MSVC toolchain links cleanly). Prove this first.
- **arm64** targets (linux + windows-cross) need their toolchains exercised in CI.
- The `versions.env` refs are starting points; pin each to an exact tag/commit
  once validated against the FFmpeg 8.1 API that Tether's rsmpeg pin expects.
- The two third-party CI actions (`ilammy/msvc-dev-cmd`, `msys2/setup-msys2`)
  are on version tags and should be pinned to commit SHAs before cutting real
  releases (GitHub security-hardening guidance). Official `actions/*` are left on
  major-version tags, which GitHub maintains.
