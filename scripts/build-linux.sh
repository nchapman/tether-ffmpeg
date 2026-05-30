#!/usr/bin/env bash
# Build a static LGPL FFmpeg for Linux. Intended to run inside the build
# container (docker/Dockerfile.linux), which provides the toolchain + libva/libdrm.
#
# Usage: scripts/build-linux.sh <arch>      arch ∈ { x86_64, arm64 }
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/flags.sh"

ARCH="${1:?usage: build-linux.sh <x86_64|arm64>}"
PREFIX="${BUILD_DIR}/linux-${ARCH}/prefix"
mkdir -p "${PREFIX}"

fetch_git ffmpeg "${FFMPEG_REPO}" "${FFMPEG_REF}"

log "configuring ffmpeg (linux/${ARCH})"
SRC="${SOURCES_DIR}/ffmpeg"
OBJ="${BUILD_DIR}/linux-${ARCH}/obj"
mkdir -p "${OBJ}"
mapfile -t FLAGS < <(configure_flags linux "${ARCH}")
( cd "${OBJ}" && "${SRC}/configure" --prefix="${PREFIX}" "${FLAGS[@]}" )

log "building ffmpeg (linux/${ARCH})"
make -C "${OBJ}" -j"$(nproc)"
make -C "${OBJ}" install

package_prefix "${PREFIX}" linux "${ARCH}"
