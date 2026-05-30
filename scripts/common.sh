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
