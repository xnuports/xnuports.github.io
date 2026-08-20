#!/bin/bash
# xnuports/pkg-bootstrap manifest generator
# Infers package metadata from directory contents and generates +MANIFEST
#
# Usage:
#   ./tools/gen-manifest.sh <package-dir> [options]
#
# Options:
#   --name=NAME            Package name (inferred from dir)
#   --version=VERSION      Package version (inferred from dir)
#   --prefix=PREFIX        Install prefix (default: /opt/xnuports/opt/<name>)
#   --category=CAT         Package category (e.g., games, devel)
#   --maintainer=EMAIL     Maintainer email
#   --arch=ARCH            Architecture (default: darwin:<os-ver>:aarch64:64)
#   --abi=ABI              ABI string (default: Darwin:<os-ver>:aarch64)
#   --license=LICENSE      SPDX license identifier
#   --www=URL              Project URL
#   --comment=COMMENT      Short description
#   --desc=DESC            Long description
#   --no-files             Don't auto-generate files list
#   --dry-run              Print manifest to stdout instead of writing
#   --help                 Show this help

set -euo pipefail

PACKAGE_DIR=""
NAME=""
VERSION=""
PREFIX=""
CATEGORY=""
MAINTAINER=""
ARCH=""
ABI=""
LICENSE=""
WWW=""
COMMENT=""
DESC=""
NO_FILES=0
DRY_RUN=0
OUTPUT_FILE="+MANIFEST"

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
xnuports/pkg-bootstrap manifest generator

Usage: $(basename "$0") <package-dir> [options]

Options:
  --name=NAME            Package name (inferred from dir)
  --version=VERSION      Package version (inferred from dir)
  --prefix=PREFIX        Install prefix (default: /opt/xnuports/opt/<name>)
  --category=CAT         Package category (e.g., games, devel)
  --maintainer=EMAIL     Maintainer email
  --arch=ARCH            Architecture (default: macOS)
  --abi=ABI              ABI string (default: macOS:arm64)
  --license=LICENSE      SPDX license identifier
  --www=URL              Project URL
  --comment=COMMENT      Short description
  --desc=DESC            Long description
  --no-files             Don't auto-generate files list
  --dry-run              Print manifest to stdout instead of writing
  --help                 Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      ;;
    --name=*)
      NAME="${1#*=}"
      shift
      ;;
    --version=*)
      VERSION="${1#*=}"
      shift
      ;;
    --prefix=*)
      PREFIX="${1#*=}"
      shift
      ;;
    --category=*)
      CATEGORY="${1#*=}"
      shift
      ;;
    --maintainer=*)
      MAINTAINER="${1#*=}"
      shift
      ;;
    --arch=*)
      ARCH="${1#*=}"
      shift
      ;;
    --abi=*)
      ABI="${1#*=}"
      shift
      ;;
    --license=*)
      LICENSE="${1#*=}"
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
    --no-files)
      NO_FILES=1
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

# Infer name and version from directory name (e.g., wizardry-1.2.2, pkg-v2.8.99.1)
dir_name="$(basename "${PACKAGE_DIR}")"
if [[ "${dir_name}" =~ ^(.+)-([0-9]+\.[0-9]+[^/]*)$ ]]; then
  INFERRED_NAME="${BASH_REMATCH[1]}"
  INFERRED_VERSION="${BASH_REMATCH[2]}"
elif [[ "${dir_name}" =~ ^pkg-(v[0-9]+\.[0-9]+[^/-]*)(-.*)?$ ]]; then
  INFERRED_NAME="pkg"
  INFERRED_VERSION="${BASH_REMATCH[1]#v}"
elif [[ "${dir_name}" =~ ^([a-zA-Z0-9_-]+)-([0-9]+\.[0-9]+[^/-]*)(-.*)?$ ]]; then
  INFERRED_NAME="${BASH_REMATCH[1]}"
  INFERRED_VERSION="${BASH_REMATCH[2]}"
else
  INFERRED_NAME="${dir_name}"
  INFERRED_VERSION="1.0.0"
fi

NAME="${NAME:-${INFERRED_NAME}}"
VERSION="${VERSION:-${INFERRED_VERSION}}"
PREFIX="${PREFIX:-/opt/xnuports/opt/${NAME}}"

# Infer maintainer from git config
if [[ -z "${MAINTAINER}" ]]; then
  GIT_NAME="$(git -C "${PACKAGE_DIR}" config user.name 2>/dev/null || true)"
  GIT_EMAIL="$(git -C "${PACKAGE_DIR}" config user.email 2>/dev/null || true)"
  if [[ -n "${GIT_NAME}" && -n "${GIT_EMAIL}" ]]; then
    MAINTAINER="${GIT_NAME} <${GIT_EMAIL}>"
  fi
fi
MAINTAINER="${MAINTAINER:-maintainer <maintainer@example.com>}"

# Infer www from git remote first, then go.mod, then README
if [[ -z "${WWW}" ]]; then
  REMOTE_URL="$(git -C "${PACKAGE_DIR}" remote get-url origin 2>/dev/null || true)"
  if [[ -n "${REMOTE_URL}" ]]; then
    REMOTE_URL="${REMOTE_URL%.git}"
    if [[ "${REMOTE_URL}" =~ ^git@ ]]; then
      REMOTE_URL="${REMOTE_URL#git@}"
      REMOTE_URL="$(echo "${REMOTE_URL}" | sed 's|:|/|')"
      WWW="https://${REMOTE_URL}"
    elif [[ "${REMOTE_URL}" =~ ^ssh:// ]]; then
      REMOTE_URL="${REMOTE_URL#ssh://}"
      REMOTE_URL="$(echo "${REMOTE_URL}" | sed 's|:|/|')"
      WWW="https://${REMOTE_URL}"
    else
      WWW="${REMOTE_URL}"
    fi
  fi
  if [[ -z "${WWW}" && -f "${PACKAGE_DIR}/go.mod" ]]; then
    MOD_NAME="$(grep -m1 '^module' "${PACKAGE_DIR}/go.mod" | awk '{print $2}')"
    if [[ -n "${MOD_NAME}" ]]; then
      WWW="https://${MOD_NAME}"
    fi
  fi
  if [[ -z "${WWW}" && -f "${PACKAGE_DIR}/README.md" ]]; then
    WWW="$(grep -m1 -o 'https://github.com/[^ )]*' "${PACKAGE_DIR}/README.md" 2>/dev/null || true)"
  fi
fi
WWW="${WWW:-https://github.com/xnuports/${NAME}}"

# Infer license from LICENSE file
if [[ -z "${LICENSE}" ]]; then
  if [[ -f "${PACKAGE_DIR}/LICENSE" ]]; then
    LIC_HEAD="$(head -5 "${PACKAGE_DIR}/LICENSE" | tr '[:upper:]' '[:lower:]')"
    if grep -qi 'mit license' <<< "${LIC_HEAD}"; then
      LICENSE="MIT"
    elif grep -qi 'apache license' <<< "${LIC_HEAD}"; then
      LICENSE="APACHE20"
    elif grep -qi 'gnu general public license' <<< "${LIC_HEAD}"; then
      LICENSE="GPL"
    elif grep -qi 'bsd' <<< "${LIC_HEAD}"; then
      LICENSE="BSD"
    fi
  fi
fi

# Infer comment/desc from README
if [[ -z "${COMMENT}" || -z "${DESC}" ]]; then
  if [[ -f "${PACKAGE_DIR}/README.md" ]]; then
    README_FIRST="$(head -20 "${PACKAGE_DIR}/README.md" | sed '/^#/d' | sed '/^$/d' | head -1)"
    if [[ -z "${COMMENT}" ]]; then
      COMMENT="${README_FIRST}"
    fi
    if [[ -z "${DESC}" ]]; then
      DESC="${README_FIRST}"
    fi
  fi
fi
COMMENT="${COMMENT:-${NAME}}"
DESC="${DESC:-${COMMENT}}"

# Prompt for missing required fields
if [[ -z "${CATEGORY}" ]]; then
  read -r -p "Category (e.g., games, devel): " CATEGORY
fi

echo "Generating manifest for ${NAME}-${VERSION}"
echo "  Name:        ${NAME}"
echo "  Version:     ${VERSION}"
echo "  Prefix:      ${PREFIX}"
echo "  Category:    ${CATEGORY}"
echo "  Maintainer:  ${MAINTAINER}"
echo "  Arch:        ${ARCH}"
echo "  ABI:         ${ABI}"
echo "  License:     ${LICENSE}"
echo "  WWW:         ${WWW}"
echo "  Comment:     ${COMMENT}"
echo "  Desc:        ${DESC}"
echo

# Build files list
FILES_YAML=""
if [[ "${NO_FILES}" -eq 0 ]]; then
  echo "Scanning files in ${PACKAGE_DIR}..."
  FILES_YAML=$(cd "${PACKAGE_DIR}" && find . -type f ! -name '+MANIFEST' ! -name '.DS_Store' ! -name '*.pkg' | sort | while read -r f; do
    f="${f#./}"
    printf '  "/%s/%s": {}\n' "${PREFIX#/}" "${f}"
  done)
  if [[ -z "${FILES_YAML}" ]]; then
    echo "Warning: no files found in ${PACKAGE_DIR}" >&2
    FILES_YAML="  # Add files here"
  fi
else
  FILES_YAML="  # Add files here"
fi

# Build manifest
LICENSE_BLOCK=""
if [[ -n "${LICENSE}" ]]; then
  LICENSE_BLOCK=$(printf 'licenses: ["%s"]\n' "${LICENSE}")
fi

MANIFEST=$(cat <<EOF
name: "${NAME}"
version: "${VERSION}"
origin: ${CATEGORY}/${NAME}
comment: "${COMMENT}"
desc: "${DESC}"
www: "${WWW}"
maintainer: "${MAINTAINER}"
arch: "${ARCH}"
abi: "${ABI}"
prefix: "${PREFIX}"
categories: [${CATEGORY}]
${LICENSE_BLOCK}
# Files to install
files: {
$(printf '%s\n' "${FILES_YAML}")
}
EOF
)

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "${MANIFEST}"
else
  OUTPUT_PATH="${PACKAGE_DIR}/${OUTPUT_FILE}"
  echo "${MANIFEST}" > "${OUTPUT_PATH}"
  echo "Wrote ${OUTPUT_PATH}"
fi
