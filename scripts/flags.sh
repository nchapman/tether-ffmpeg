#!/usr/bin/env bash
# Emit FFmpeg ./configure flags for a given (os, arch).
#
# Two invariants hold across every target:
#   * LGPL only — no --enable-gpl / --enable-nonfree, no libx264 / libx265.
#     Tether's *video* path runs exclusively through hardware codecs, all of which
#     are LGPL-compatible (vaapi, videotoolbox, nvenc, amf, qsv, mediafoundation).
#     The one software codec is libopus (Opus audio): BSD-licensed, so still
#     LGPL-compatible, built static from source and enabled on every target.
#   * Static libs — the final tether-host/tether-client binaries embed FFmpeg;
#     only stable system pieces (libva, OS frameworks, MF) stay dynamic.
#
# Usage: configure_flags <os> <arch>   (prints flags, one per line)
configure_flags() {
  local os="$1" arch="$2"

  # Common base: LGPL, static, lib-only. libopus (Opus audio) is the one software
  # codec and is built/installed into the prefix on every target, so it's enabled
  # here rather than per-platform; FFmpeg's configure finds it via opus.pc.
  cat <<'EOF'
--disable-gpl
--disable-nonfree
--disable-shared
--enable-static
--enable-pic
--disable-programs
--disable-doc
--disable-debug
--enable-libopus
EOF

  case "${os}" in
    linux)
      # Tether's Linux host path is VAAPI (the universal baseline) plus NVENC on
      # NVIDIA hosts. libva/libdrm are linked from the build container and resolve
      # against the system libs at final link time.
      echo "--enable-vaapi"
      echo "--enable-libdrm"
      # NVENC + the CUDA hwcontext. ffnvcodec.pc (installed into the prefix by
      # build-linux.sh) satisfies configure; both dlopen their runtime libs
      # (libnvidia-encode.so / libcuda.so) on an actual NVIDIA host, so this adds no
      # build-time toolkit dependency and stays within the LGPL/static invariant.
      # --enable-cuda provides AV_HWDEVICE_TYPE_CUDA, which the host uses to import a
      # capture DMA-BUF into CUDA zero-copy and feed *_nvenc. Enabled on both arches —
      # NVENC exists on ARM NVIDIA too; the runtime libs load only when a GPU is present.
      echo "--enable-nvenc"
      echo "--enable-cuda"
      ;;
    macos)
      echo "--enable-videotoolbox"
      # GitHub's macos runners ship Homebrew libx11/libxcb, which FFmpeg's
      # configure auto-detects and uses to enable the x11grab/xcbgrab screen
      # capture indevs. That bakes the runner's `-L/opt/homebrew/Cellar/...`
      # paths and `-lX11 -lxcb*` into libavutil.pc/libavdevice.pc, so any
      # consumer's static link then depends on those exact Homebrew packages
      # being installed (and makes the artifact non-reproducible w.r.t. runner
      # brew state). Tether captures via ScreenCaptureKit and never touches
      # these indevs, so disable both — the build stays OS-framework-only.
      echo "--disable-xlib"
      echo "--disable-libxcb"
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
        # CUDA hwcontext (AV_HWDEVICE_TYPE_CUDA), for parity with the Linux build.
        # ffnvcodec is already installed for --enable-nvenc and the runtime dlopens
        # libcuda, so this needs no extra toolkit. Today's Windows NVENC path feeds
        # D3D11 textures and doesn't require it; enabling it keeps the encoder matrix
        # symmetric across platforms and unblocks a future CUDA-based input path.
        echo "--enable-cuda"
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
