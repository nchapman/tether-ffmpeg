#!/usr/bin/env bash
# Build a static LGPL FFmpeg for macOS (runs natively on a macos-14 arm64 runner).
# VideoToolbox is an OS framework; the only third-party dep built here is the
# bundled static libopus (via cmake, preinstalled on the runner).
#
# Usage: scripts/build-macos.sh <arch>      arch ∈ { arm64, x86_64 }
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/flags.sh"

ARCH="${1:?usage: build-macos.sh <arm64|x86_64>}"
PREFIX="${BUILD_DIR}/macos-${ARCH}/prefix"
mkdir -p "${PREFIX}"

# Opus audio codec: built static into the prefix before FFmpeg so its opus.pc is
# in place when configure runs the --enable-libopus check.
build_libopus macos "${ARCH}" "${PREFIX}"

fetch_git ffmpeg "${FFMPEG_REPO}" "${FFMPEG_REF}"

log "configuring ffmpeg (macos/${ARCH})"
SRC="${SOURCES_DIR}/ffmpeg"
OBJ="${BUILD_DIR}/macos-${ARCH}/obj"
mkdir -p "${OBJ}"
# Portable array fill — macOS ships bash 3.2, which has no `mapfile`/`readarray`.
FLAGS=()
while IFS= read -r _flag; do FLAGS+=("${_flag}"); done < <(configure_flags macos "${ARCH}")
# Point pkg-config at our prefix so configure finds opus.pc.
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
( cd "${OBJ}" && "${SRC}/configure" --prefix="${PREFIX}" "${FLAGS[@]}" )

log "building ffmpeg (macos/${ARCH})"
make -C "${OBJ}" -j"$(sysctl -n hw.ncpu)"
make -C "${OBJ}" install

package_prefix "${PREFIX}" macos "${ARCH}"
