# tether-ffmpeg

LGPL-only, statically linkable **FFmpeg 8.1** builds for every platform
[Tether](https://github.com/nchapman/tether) runs on. CI builds one tarball per
`(os, arch)` and publishes them as GitHub Release assets.

## Targets

| OS | Arch | Hardware codecs |
|----|------|-----------------|
| linux | x86_64, arm64 | VAAPI |
| macos | arm64 | VideoToolbox |
| windows | x86_64 | NVENC, AMF, QSV, Media Foundation, D3D11VA |
| windows | arm64 | Media Foundation, D3D11VA |

Each tarball holds static `lib*.a` / `*.lib`, headers, and `lib/pkgconfig/*.pc`.
No GPL — no `--enable-gpl`, no `libx264` / `libx265`.

## Use a build

Grab the tarball for your `(os, arch)` from the
[latest release](https://github.com/nchapman/tether-ffmpeg/releases/latest),
verify it, and point pkg-config at it:

```sh
sha256sum -c tether-ffmpeg-*.tar.xz.sha256                              # checksum
gh attestation verify tether-ffmpeg-*.tar.xz --repo nchapman/tether-ffmpeg  # provenance
tar xf tether-ffmpeg-*.tar.xz
export PKG_CONFIG_PATH="$PWD/prefix/lib/pkgconfig"
```

## Cut a release

1. Bump the pins / `TETHER_FFMPEG_VERSION` in [`versions.env`](versions.env).
2. Push a tag `v<TETHER_FFMPEG_VERSION>` (e.g. `v8.1.0-tether.1`).
3. CI builds every target and publishes the Release.

Version is `<ffmpeg-version>-tether.<N>`: bump the FFmpeg part for a new FFmpeg,
the `-tether.N` suffix for a packaging-only change (flags, dep bumps).

## Build locally

```sh
scripts/build-linux.sh    x86_64   # or arm64; needs nasm, pkg-config, libva-dev, libdrm-dev
scripts/build-macos.sh    arm64
scripts/build-windows.ps1 -Arch x86_64   # from a VS dev shell with MSYS2; or arm64
```

Outputs land in `dist/`.
