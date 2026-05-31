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
      # toolchain. -MD keeps the CRT dynamic, matching Rust's default (and the
      # VC runtime DLLs we ship). cl.exe defaults to the *static* CRT (/MT) with
      # no /M flag, so the flag must cover BOTH the C objects (--extra-cflags)
      # and the C++ ones (--extra-cxxflags): e.g. the gfxcapture filter's
      # vsrc_gfxcapture_winrt.cpp, whose lone /MT object otherwise drags in
      # libcpmt/LIBCMT and collides (LNK2038/LNK2005) with every /MD object when
      # the static libs are linked into Rust.
      echo "--toolchain=msvc"
      echo "--extra-cflags=-MD"
      echo "--extra-cxxflags=-MD"
      # MSYS2 ships pkg-config as the `pkgconf` binary (no `pkg-config` name), so
      # point configure at it explicitly — otherwise every .pc lookup (libvpl,
      # ffnvcodec) silently fails with "pkg-config not found".
      echo "--pkg-config=pkgconf"
      echo "--enable-mediafoundation"
      echo "--enable-d3d11va"
      echo "--enable-dxva2"
      if [[ "${arch}" == "x86_64" ]]; then
        # x64-only vendor encoders. None exist on Windows arm64.
        echo "--enable-nvenc"
        echo "--enable-amf"
        # libvpl's static link needs advapi32/ole32 (see build-windows.ps1,
        # which patches vpl.pc so pkg-config advertises them).
        echo "--enable-libvpl"
        # The amf_capture filter (vsrc_amf.c) includes AMF's DisplayCapture.h,
        # a C++-only header (unguarded `extern "C"`) that FFmpeg compiles as C →
        # syntax error. Tether captures on its own and only needs the AMF
        # *encoders*, so drop this filter rather than the whole AMF feature.
        echo "--disable-filter=amf_capture"
      elif [[ "${arch}" == "arm64" ]]; then
        echo "--enable-cross-compile"
        echo "--arch=aarch64"
        echo "--target-os=win32"
        # MSVC arm64 has no GNU assembler, and FFmpeg's aarch64 asm path needs
        # gas-preprocessor + armasm64 (fragile to wire up in CI). Tether decodes/
        # encodes only through hardware codecs, so FFmpeg's software SIMD is moot —
        # disable asm rather than carry the gas-preprocessor dependency.
        echo "--disable-asm"
      fi
      ;;
    *)
      echo "unknown os: ${os}" >&2; return 1 ;;
  esac
}
