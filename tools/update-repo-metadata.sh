#!/bin/bash
# xnuports repository metadata regenerator
# Scans for .pkg files and rebuilds the pkg repository catalogue
# (packagesite.pkg, data.pkg, meta) for GitHub Pages hosting.
#
# Usage:
#   ./tools/update-repo-metadata.sh [repo-path ...]
#
# If no repo-path is given, updates both:
#   packages/macOS-arm64/latest
#   packages/macOS-x86_64/latest
#
# Requirements:
#   - pkg binary installed at /opt/xnuports/sbin/pkg
#   - At least one .pkg file in each repo's packages/ directory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<EOF
xnuports repository metadata regenerator

Usage: $(basename "$0") [repo-path ...]

Rebuilds the pkg repository catalogue files (meta, packagesite.pkg,
data.pkg) for one or more architecture-specific repositories.

If no repo-path is given, defaults to:
    packages/macOS-arm64/latest
    packages/macOS-x86_64/latest

The script runs 'pkg repo' on each target directory, which scans for
.pkg files and regenerates the repository index. Existing meta.conf
files are preserved.
EOF
  exit 0
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
fi

# Detect pkg binary
PKG_BIN=""
if command -v pkg >/dev/null 2>&1; then
  PKG_BIN="$(command -v pkg)"
elif [[ -x "/opt/xnuports/sbin/pkg" ]]; then
  PKG_BIN="/opt/xnuports/sbin/pkg"
elif [[ -x "/opt/xnuports/bin/pkg" ]]; then
  PKG_BIN="/opt/xnuports/bin/pkg"
else
  echo "Error: pkg not found. Install xnuports/pkg first or ensure it's in PATH." >&2
  exit 1
fi

REPO_PATHS=()
if [[ $# -eq 0 ]]; then
  REPO_PATHS+=("${REPO_ROOT}/packages/macOS-arm64/latest")
  REPO_PATHS+=("${REPO_ROOT}/packages/macOS-x86_64/latest")
else
  for arg in "$@"; do
    REPO_PATHS+=("${arg}")
  done
fi

FAILED=0
for repo in "${REPO_PATHS[@]}"; do
  if [[ ! -d "${repo}" ]]; then
    echo "Skipping ${repo}: directory not found"
    continue
  fi

  PACKAGES_DIR="${repo}/packages"
  if [[ ! -d "${PACKAGES_DIR}" ]]; then
    echo "Skipping ${repo}: no packages/ directory"
    continue
  fi

  PKG_COUNT=$(find "${PACKAGES_DIR}" -maxdepth 1 -name "*.pkg" -type f 2>/dev/null | wc -l)
  if [[ "${PKG_COUNT}" -eq 0 ]]; then
    echo "Skipping ${repo}: no .pkg files found in ${PACKAGES_DIR}"
    continue
  fi

  echo "==> Updating ${repo} (${PKG_COUNT} package(s))"
  if ! "${PKG_BIN}" repo "${repo}" 2>&1; then
    echo "Error: pkg repo failed for ${repo}" >&2
    FAILED=1
    continue
  fi

  echo "==> Generated:"
  for f in meta packagesite.pkg data.pkg; do
    if [[ -f "${repo}/${f}" ]]; then
      echo "    ${f} ($(stat -f%z "${repo}/${f}" 2>/dev/null || stat -c%s "${repo}/${f}" 2>/dev/null || echo "?") bytes)"
    fi
  done
  echo ""
done

if [[ "${FAILED}" -ne 0 ]]; then
  echo "Error: one or more repository updates failed." >&2
  exit 1
fi

echo "==> Done. Commit the updated meta, packagesite.pkg, and data.pkg files."
