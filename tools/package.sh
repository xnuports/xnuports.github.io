#!/bin/bash
# xnuports package builder
# Generates +MANIFEST and creates a .pkg package from a staging directory
#
# Usage:
#   ./tools/package.sh <package-dir> [options]
#
# Options:
#   --output=DIR           Output directory (default: <package-dir>/..)
#   --category=CAT         Package category (e.g., games, devel)
#   --abi=ABI              ABI string (default: Darwin:<os-ver>:aarch64)
#   --arch=ARCH            Architecture (default: darwin:<os-ver>:aarch64:64)
#   --license=LICENSE      SPDX license identifier
#   --version=VERSION      Package version (overrides inferred version)
#   --maintainer=EMAIL     Maintainer email
#   --www=URL              Project URL
#   --comment=COMMENT      Short description
#   --desc=DESC            Long description
#   --no-manifest          Skip manifest generation (use existing +MANIFEST)
#   --allow-build-paths    Skip the check for leaked build/staging paths
#   --dry-run              Print manifest and commands without executing
#   --help                 Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN_MANIFEST="${SCRIPT_DIR}/gen-manifest.sh"

PACKAGE_DIR=""
OUTPUT_DIR=""
CATEGORY=""
PREFIX=""
ARCH=""
ABI=""
LICENSE=""
VERSION=""
MAINTAINER=""
WWW=""
COMMENT=""
DESC=""
NO_MANIFEST=0
DRY_RUN=0
ALLOW_BUILD_PATHS=0

# Detect default arch/abi matching pkg_bootstrap conventions
XNUPORTS_OS_VERSION="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1 || echo 26)"
XNUPORTS_ARCH="$(uname -m 2>/dev/null || echo arm64)"
if [[ "${XNUPORTS_ARCH}" == "arm64" ]]; then
  ARCH_PKG="aarch64"
  ARCH_MANIFEST="darwin:${XNUPORTS_OS_VERSION}:aarch64:64"
else
  ARCH_PKG="${XNUPORTS_ARCH}"
  ARCH_MANIFEST="darwin:${XNUPORTS_OS_VERSION}:amd64:64"
fi
ABI="Darwin:${XNUPORTS_OS_VERSION}:${ARCH_PKG}"
ARCH="${ARCH_MANIFEST}"

usage() {
  cat <<EOF
xnuports package builder

Usage: $(basename "$0") <package-dir> [options]

Options:
  --output=DIR           Output directory (default: <package-dir>/..)
  --category=CAT         Package category (e.g., games, devel)
  --prefix=PREFIX        Install prefix (default: /opt/xnuports/opt/<name>; use / for system-layout packages)
  --abi=ABI              ABI string (default: macOS:arm64)
  --arch=ARCH            Architecture (default: macOS)
  --license=LICENSE      SPDX license identifier
  --version=VERSION      Package version (overrides inferred version)
  --www=URL              Project URL
  --comment=COMMENT      Short description
  --desc=DESC            Long description
  --no-manifest          Skip manifest generation (use existing +MANIFEST)
  --allow-build-paths    Skip the check for leaked build/staging paths
  --dry-run              Print manifest and commands without executing
  --help                 Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      ;;
    --output=*)
      OUTPUT_DIR="${1#*=}"
      shift
      ;;
    --category=*)
      CATEGORY="${1#*=}"
      shift
      ;;
    --prefix=*)
      PREFIX="${1#*=}"
      shift
      ;;
    --abi=*)
      ABI="${1#*=}"
      shift
      ;;
    --arch=*)
      ARCH="${1#*=}"
      shift
      ;;
    --license=*)
      LICENSE="${1#*=}"
      shift
      ;;
    --version=*)
      VERSION="${1#*=}"
      shift
      ;;
    --maintainer=*)
      MAINTAINER="${1#*=}"
      shift
      ;;
    --www=*)
      WWW="${1#*=}"
      shift
      ;;
    --comment=*)
      COMMENT="${1#*=}"
      shift
      ;;
    --desc=*)
      DESC="${1#*=}"
      shift
      ;;
    --no-manifest)
      NO_MANIFEST=1
      shift
      ;;
    --allow-build-paths)
      ALLOW_BUILD_PATHS=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "${PACKAGE_DIR}" ]]; then
        PACKAGE_DIR="$1"
      else
        echo "Error: unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "${PACKAGE_DIR}" ]]; then
  echo "Error: package directory required" >&2
  usage
fi

if [[ ! -d "${PACKAGE_DIR}" ]]; then
  echo "Error: directory not found: ${PACKAGE_DIR}" >&2
  exit 1
fi

PACKAGE_DIR="$(cd "${PACKAGE_DIR}" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$(dirname "${PACKAGE_DIR}")}"

# Check for pkg binary
PKG_BIN=""
if command -v pkg >/dev/null 2>&1; then
  PKG_BIN="pkg"
elif [[ -x "/opt/xnuports/bin/pkg" ]]; then
  PKG_BIN="/opt/xnuports/bin/pkg"
elif [[ -x "/opt/xnuports/sbin/pkg" ]]; then
  PKG_BIN="/opt/xnuports/sbin/pkg"
else
  echo "Error: pkg not found. Install xnuports/pkg first or ensure it's in PATH." >&2
  exit 1
fi

# Generate manifest if needed
MANIFEST_ARGS=(--dry-run)
if [[ -n "${CATEGORY}" ]]; then
  MANIFEST_ARGS+=(--category="${CATEGORY}")
fi
if [[ -n "${PREFIX}" ]]; then
  MANIFEST_ARGS+=(--prefix="${PREFIX}")
fi
if [[ -n "${ABI}" ]]; then
  MANIFEST_ARGS+=(--abi="${ABI}")
fi
if [[ -n "${ARCH}" ]]; then
  MANIFEST_ARGS+=(--arch="${ARCH}")
fi
if [[ -n "${LICENSE}" ]]; then
  MANIFEST_ARGS+=(--license="${LICENSE}")
fi
if [[ -n "${VERSION}" ]]; then
  MANIFEST_ARGS+=(--version="${VERSION}")
fi
if [[ -n "${MAINTAINER}" ]]; then
  MANIFEST_ARGS+=(--maintainer="${MAINTAINER}")
fi
if [[ -n "${WWW}" ]]; then
  MANIFEST_ARGS+=(--www="${WWW}")
fi
if [[ -n "${COMMENT}" ]]; then
  MANIFEST_ARGS+=(--comment="${COMMENT}")
fi
if [[ -n "${DESC}" ]]; then
  MANIFEST_ARGS+=(--desc="${DESC}")
fi

MANIFEST_CONTENT=""
if [[ "${NO_MANIFEST}" -eq 0 ]]; then
  echo "=== Generating manifest ==="
  MANIFEST_CONTENT=$("${GEN_MANIFEST}" "${PACKAGE_DIR}" "${MANIFEST_ARGS[@]}")
  echo "${MANIFEST_CONTENT}"
  echo
elif [[ ! -f "${PACKAGE_DIR}/+MANIFEST" ]]; then
  echo "Error: --no-manifest specified but no +MANIFEST found in ${PACKAGE_DIR}" >&2
  exit 1
fi

# Determine package name and version from manifest content or directory
if [[ -n "${MANIFEST_CONTENT}" ]]; then
  PKG_NAME="$(echo "${MANIFEST_CONTENT}" | grep -m1 '^name:' | awk '{print $2}' | tr -d '"')"
  PKG_VERSION="$(echo "${MANIFEST_CONTENT}" | grep -m1 '^version:' | awk '{print $2}' | tr -d '"')"
  PKG_PREFIX="$(echo "${MANIFEST_CONTENT}" | grep -m1 '^prefix:' | awk '{print $2}' | tr -d '"')"
else
  PKG_NAME="$(grep -m1 '^name:' "${PACKAGE_DIR}/+MANIFEST" | awk '{print $2}' | tr -d '"')"
  PKG_VERSION="$(grep -m1 '^version:' "${PACKAGE_DIR}/+MANIFEST" | awk '{print $2}' | tr -d '"')"
  PKG_PREFIX="$(grep -m1 '^prefix:' "${PACKAGE_DIR}/+MANIFEST" | awk '{print $2}' | tr -d '"')"
fi
PKG_NAME="${PKG_NAME:-$(basename "${PACKAGE_DIR}")}"
PKG_VERSION="${PKG_VERSION:-1.0.0}"
PKG_PREFIX="${PKG_PREFIX:-/opt/xnuports/opt/${PKG_NAME}}"

OUTPUT_FILE="${OUTPUT_DIR}/${PKG_NAME}-${PKG_VERSION}.pkg"

# Create a temporary staging directory with the correct filesystem layout
STAGING_DIR="$(mktemp -d -t xnuports-pkg-staging)"
trap 'rm -rf "${STAGING_DIR}"' EXIT

echo "=== Staging files ==="
echo "  Source:  ${PACKAGE_DIR}"
echo "  Staging: ${STAGING_DIR}"
echo

# Copy files from package dir to staging dir, maintaining the target layout
if [[ -n "${MANIFEST_CONTENT}" ]]; then
  # Parse files from generated manifest content
  echo "${MANIFEST_CONTENT}" | awk '/^files: \{/,/^\}$/' | grep -E '^\s+"\/' | while IFS= read -r line; do
    dest_path="$(echo "${line}" | sed -E 's/^[[:space:]]*"([^"]+)".*/\1/')"
    # Strip prefix to get relative path
    rel_path="${dest_path#${PKG_PREFIX}}"
    src_path="${PACKAGE_DIR}/${rel_path#/}"
    dst_path="${STAGING_DIR}/${dest_path#/}"
    if [[ -f "${src_path}" ]]; then
      mkdir -p "$(dirname "${dst_path}")"
      cp "${src_path}" "${dst_path}"
      echo "  ${src_path} -> ${dst_path}"
    else
      echo "  Warning: source file not found: ${src_path}" >&2
    fi
  done
else
  # Use existing manifest
  awk '/^files: \{/,/^\}$/' "${PACKAGE_DIR}/+MANIFEST" | grep -E '^\s+"\/' | while IFS= read -r line; do
    dest_path="$(echo "${line}" | sed -E 's/^[[:space:]]*"([^"]+)".*/\1/')"
    rel_path="${dest_path#${PKG_PREFIX}}"
    src_path="${PACKAGE_DIR}/${rel_path#/}"
    dst_path="${STAGING_DIR}/${dest_path#/}"
    if [[ -f "${src_path}" ]]; then
      mkdir -p "$(dirname "${dst_path}")"
      cp "${src_path}" "${dst_path}"
      echo "  ${src_path} -> ${dst_path}"
    else
      echo "  Warning: source file not found: ${src_path}" >&2
    fi
  done
fi

# Write manifest to staging dir
if [[ -n "${MANIFEST_CONTENT}" ]]; then
  echo "${MANIFEST_CONTENT}" > "${STAGING_DIR}/+MANIFEST"
else
  cp "${PACKAGE_DIR}/+MANIFEST" "${STAGING_DIR}/+MANIFEST"
fi

# ─── Build-path leak check ───────────────────────────────────────────────────
#
# Catches the class of bug where a package is built with
# './configure --prefix=<staging dir>', which bakes the staging path into the
# binary as a runtime lookup path. The package installs fine, then fails at
# runtime once the staging tree moves or is deleted.
#
# This is what broke bmake-1.394: it was configured with --prefix pointing at
# staging/bmake-1.394, so _PATH_DEFSYSPATH pointed there and bmake could not
# find sys.mk from anywhere.
#
# The correct pattern is to configure with the real runtime prefix and stage
# via DESTDIR:
#
#   ./configure --prefix=/opt/xnuports/opt/<name>
#   make install DESTDIR=<staging dir>
#
# Only the staging and build directories are checked, deliberately. Source
# paths left in debug info (DWARF entries, Go module paths) are cosmetic and
# would produce constant false positives.
#
# NOTE: grep needs -a here. On macOS, grep without -a does not report matches
# in binary files, which is exactly where these paths live.
if [[ "${ALLOW_BUILD_PATHS}" -eq 0 ]]; then
  echo "=== Checking for leaked build paths ==="
  LEAK_FOUND=0
  while IFS= read -r staged_file; do
    [[ "$(basename "${staged_file}")" == "+MANIFEST" ]] && continue
    if grep -qa -e "${PACKAGE_DIR}" -e "${STAGING_DIR}" "${staged_file}" 2>/dev/null; then
      if [[ "${LEAK_FOUND}" -eq 0 ]]; then
        echo "  Error: staged files reference the build/staging directory:" >&2
      fi
      echo "    ${staged_file#${STAGING_DIR}}" >&2
      LEAK_FOUND=1
    fi
  done < <(find "${STAGING_DIR}" -type f)

  if [[ "${LEAK_FOUND}" -ne 0 ]]; then
    cat >&2 <<LEAKMSG

  These files embed a path that will not exist on the target system:
    ${PACKAGE_DIR}

  This usually means the software was configured with
  '--prefix=${PACKAGE_DIR}'. Rebuild with the real runtime prefix and
  stage the install instead:

    ./configure --prefix=${PKG_PREFIX}
    make install DESTDIR=<staging dir>

  Re-run with --allow-build-paths if the reference is harmless
  (for example a path that only appears in debug information).

LEAKMSG
    exit 1
  fi
  echo "  OK: no build paths leaked into staged files"
  echo
fi

echo
echo "=== Building package ==="
echo "  Input:  ${STAGING_DIR}"
echo "  Output: ${OUTPUT_FILE}"
echo "  pkg:    ${PKG_BIN}"
echo

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "Dry run: would execute"
  echo "  ${PKG_BIN} create -m '${STAGING_DIR}/+MANIFEST' -r '${STAGING_DIR}' -o '${OUTPUT_DIR}'"
  exit 0
fi

# Create the package from the staging directory
"${PKG_BIN}" create \
  -m "${STAGING_DIR}/+MANIFEST" \
  -r "${STAGING_DIR}" \
  -o "${OUTPUT_DIR}"

echo
echo "Package created: ${OUTPUT_FILE}"
echo

# Show package info
"${PKG_BIN}" info -F "${OUTPUT_FILE}" || true
