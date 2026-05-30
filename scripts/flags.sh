#!/usr/bin/env bash
# Emit FFmpeg ./configure flags for a given (os, arch).
#
# Two invariants hold across every target:
#   * LGPL only — no --enable-gpl / --enable-nonfree, no libx264 / libx265.
#     Tether encodes/decodes exclusively through hardware codecs, all of which
#     are LGPL-compatible (vaapi, videotoolbox, nvenc, amf, qsv, mediafoundation).
#   * Static libs — the final tether-host/tether-client binaries embed FFmpeg;
#     only stable system pieces (libva, OS frameworks, MF) stay dynamic.
#
# Usage: configure_flags <os> <arch>   (prints flags, one per line)
configure_flags() {
  local os="$1" arch="$2"

  # Common base: LGPL, static, lib-only.
  cat <<'EOF'
--disable-gpl
--disable-nonfree
--disable-shared
--enable-static
--enable-pic
--disable-programs
--disable-doc
--disable-debug
EOF

  case "${os}" in
    linux)
      # Tether's Linux host path is VAAPI only. libva/libdrm are linked from the
      # build container and resolve against the system libs at final link time.
      echo "--enable-vaapi"
      echo "--enable-libdrm"
      ;;
    macos)
      echo "--enable-videotoolbox"
      [[ "${arch}" == "arm64" ]] && echo "--enable-cross-compile" && echo "--arch=arm64"
      [[ "${arch}" == "x86_64" ]] && echo "--arch=x86_64"
      ;;
    windows)
      # MSVC toolchain so the static .lib match the Rust x86_64-pc-windows-msvc
      # toolchain. -MD keeps the CRT dynamic, matching Rust's default.
      echo "--toolchain=msvc"
      echo "--extra-cflags=-MD"
      echo "--enable-mediafoundation"
      echo "--enable-d3d11va"
      echo "--enable-dxva2"
      if [[ "${arch}" == "x86_64" ]]; then
        # x64-only vendor encoders. None exist on Windows arm64.
        echo "--enable-nvenc"
        echo "--enable-amf"
        echo "--enable-libvpl"
      elif [[ "${arch}" == "arm64" ]]; then
        echo "--enable-cross-compile"
        echo "--arch=aarch64"
        echo "--target-os=win32"
      fi
      ;;
    *)
      echo "unknown os: ${os}" >&2; return 1 ;;
  esac
}
