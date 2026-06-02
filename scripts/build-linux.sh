#!/usr/bin/env bash
# Build a static LGPL FFmpeg for Linux. Runs directly on the runner; CI installs
# the toolchain (build-essential, cmake, nasm, pkg-config) + libva/libdrm-dev first.
# cmake builds the bundled static libopus.
#
# Usage: scripts/build-linux.sh <arch>      arch ∈ { x86_64, arm64 }
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/flags.sh"

ARCH="${1:?usage: build-linux.sh <x86_64|arm64>}"
PREFIX="${BUILD_DIR}/linux-${ARCH}/prefix"
mkdir -p "${PREFIX}"

# Opus audio codec: built static into the prefix before FFmpeg so its opus.pc is
# in place when configure runs the --enable-libopus check.
build_libopus linux "${ARCH}" "${PREFIX}"

fetch_git ffmpeg "${FFMPEG_REPO}" "${FFMPEG_REF}"

log "configuring ffmpeg (linux/${ARCH})"
SRC="${SOURCES_DIR}/ffmpeg"
OBJ="${BUILD_DIR}/linux-${ARCH}/obj"
mkdir -p "${OBJ}"
# Portable array fill (avoid `mapfile`/`readarray`, absent in bash 3.x).
FLAGS=()
while IFS= read -r _flag; do FLAGS+=("${_flag}"); done < <(configure_flags linux "${ARCH}")
# Point pkg-config at our prefix so configure finds opus.pc; prepend (don't replace)
# so libva/libdrm still resolve from the default system pkg-config path.
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
( cd "${OBJ}" && "${SRC}/configure" --prefix="${PREFIX}" "${FLAGS[@]}" )

log "building ffmpeg (linux/${ARCH})"
make -C "${OBJ}" -j"$(nproc)"
make -C "${OBJ}" install

package_prefix "${PREFIX}" linux "${ARCH}"
