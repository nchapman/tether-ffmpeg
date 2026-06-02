#!/usr/bin/env bash
# Shared helpers for the unix (linux/macos) build scripts.
set -euo pipefail

# Resolve repo root regardless of where the script is invoked from.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${REPO_ROOT}/versions.env"

SOURCES_DIR="${REPO_ROOT}/sources"
BUILD_DIR="${REPO_ROOT}/build"
DIST_DIR="${REPO_ROOT}/dist"

log() { printf '\033[36m[tether-ffmpeg]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[tether-ffmpeg] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Shallow-clone a git repo at an exact ref into sources/<name>.
fetch_git() {
  local name="$1" repo="$2" ref="$3" dest="${SOURCES_DIR}/$1"
  if [[ -d "${dest}/.git" ]]; then
    log "${name}: already fetched (${ref})"
    return
  fi
  log "${name}: cloning ${repo} @ ${ref}"
  mkdir -p "${SOURCES_DIR}"
  git clone --quiet --depth 1 --branch "${ref}" "${repo}" "${dest}" 2>/dev/null \
    || git clone --quiet "${repo}" "${dest}"  # ref may be a SHA, not a branch/tag
  ( cd "${dest}" && git checkout --quiet "${ref}" )
}

# Build static libopus from a pinned git tag and install it into <prefix>.
# Opus is software (not a system framework), so we vendor + build it like libvpl
# on Windows: static, PIC (to match FFmpeg's --enable-pic), no tests/programs. The
# CMake install emits prefix/lib/pkgconfig/opus.pc, which FFmpeg's --enable-libopus
# check then locates via PKG_CONFIG_PATH (set by the build scripts before configure).
#
# Usage: build_libopus <os> <arch> <prefix>
build_libopus() {
  local os="$1" arch="$2" prefix="$3"
  fetch_git opus "${LIBOPUS_REPO}" "${LIBOPUS_REF}"

  local src="${SOURCES_DIR}/opus"
  local obj="${BUILD_DIR}/${os}-${arch}/opus"
  # macOS may cross-compile (e.g. x86_64 on an arm64 runner); pin the slice so the
  # static lib's arch matches the FFmpeg build. Linux builds native, so no flag.
  local osx_arch=()
  [[ "${os}" == "macos" ]] && osx_arch+=("-DCMAKE_OSX_ARCHITECTURES=${arch}")

  log "building libopus (${os}/${arch})"
  # ${arr[@]+"${arr[@]}"} guards the empty-array case: under bash 3.2 (macOS's
  # /bin/bash) with `set -u`, a bare "${osx_arch[@]}" on an empty array is a fatal
  # unbound-variable error. The guard expands to nothing when osx_arch is empty.
  cmake -S "${src}" -B "${obj}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DOPUS_BUILD_TESTING=OFF \
    -DOPUS_BUILD_PROGRAMS=OFF \
    -DCMAKE_INSTALL_PREFIX="${prefix}" \
    ${osx_arch[@]+"${osx_arch[@]}"}
  cmake --build "${obj}" --target install --parallel

  # Static libopus references libm (exp/log/... in the celt/silk DSP), but lists
  # -lm under Libs.private, not Libs. FFmpeg's libopus check links its test program
  # with the *public* Libs only (we don't pass --pkg-config-flags=--static, matching
  # the libvpl .pc convention), so on Linux — where libm is a separate lib — the test
  # link fails with undefined math symbols and configure reports the catch-all
  # "opus not found using pkg-config". Surface Libs.private onto the public Libs line
  # so the test (and any static consumer) links. No-op on macOS (libm is in libSystem)
  # but harmless. Portable across BSD/GNU sed: no -i, '|' delimiter, write-then-move.
  local pc="${prefix}/lib/pkgconfig/opus.pc"
  local priv
  priv="$(sed -n 's/^Libs\.private:[[:space:]]*//p' "${pc}")"
  if [[ -n "${priv}" ]]; then
    sed "s|^\(Libs:.*\)\$|\1 ${priv}|" "${pc}" > "${pc}.tmp" && mv "${pc}.tmp" "${pc}"
  fi
}

# Package a finished install prefix into dist/<artifact>.tar.xz + .sha256.
package_prefix() {
  local prefix="$1" os="$2" arch="$3"
  local name="tether-ffmpeg-${TETHER_FFMPEG_VERSION}-${os}-${arch}-lgpl-static"
  mkdir -p "${DIST_DIR}"
  log "packaging ${name}.tar.xz"
  tar -C "$(dirname "${prefix}")" -cJf "${DIST_DIR}/${name}.tar.xz" "$(basename "${prefix}")"
  ( cd "${DIST_DIR}" && shasum -a 256 "${name}.tar.xz" > "${name}.tar.xz.sha256" )
  log "wrote ${DIST_DIR}/${name}.tar.xz"
}
