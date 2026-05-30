#!/usr/bin/env bash
# Build a static LGPL FFmpeg for macOS (runs natively on a macos-14 arm64 runner).
# VideoToolbox is an OS framework, so there are no third-party deps to build.
#
# Usage: scripts/build-macos.sh <arch>      arch ∈ { arm64, x86_64 }
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/flags.sh"

ARCH="${1:?usage: build-macos.sh <arm64|x86_64>}"
PREFIX="${BUILD_DIR}/macos-${ARCH}/prefix"
mkdir -p "${PREFIX}"

fetch_git ffmpeg "${FFMPEG_REPO}" "${FFMPEG_REF}"

log "configuring ffmpeg (macos/${ARCH})"
SRC="${SOURCES_DIR}/ffmpeg"
OBJ="${BUILD_DIR}/macos-${ARCH}/obj"
mkdir -p "${OBJ}"
mapfile -t FLAGS < <(configure_flags macos "${ARCH}")
( cd "${OBJ}" && "${SRC}/configure" --prefix="${PREFIX}" "${FLAGS[@]}" )

log "building ffmpeg (macos/${ARCH})"
make -C "${OBJ}" -j"$(sysctl -n hw.ncpu)"
make -C "${OBJ}" install

package_prefix "${PREFIX}" macos "${ARCH}"
