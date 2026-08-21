#!/bin/bash
# xnuports source builder
# Detects the build system in a source tree, compiles it with the runtime
# prefix baked in, stages the install, and hands the result to package.sh.
#
# Usage:
#   ./tools/build-package.sh <source-dir> [options]
#
# The central rule this script exists to enforce: software is configured with
# the prefix it will actually run from (/opt/xnuports/opt/<name>) and the files
# are captured with DESTDIR. Configuring with --prefix=<staging dir> instead
# bakes a build-time path into the binary, which produces a package that
# installs cleanly and then fails at runtime once the staging tree is gone.
# That is how bmake-1.394 shipped broken.
#
# Exception: base-system style ports (xcode-tools) install to absolute paths
# (/etc, /usr/bin, /Applications) and can never live under a prefix. When
# nothing lands under PREFIX but DESTDIR has content, the whole DESTDIR tree
# is staged and packaged with prefix=/ instead of failing.
#
# Options:
#   --name=NAME            Package name (default: inferred from dir/go.mod)
#   --version=VERSION      Package version (default: inferred from dir/git tag)
#   --category=CAT         Package category (default: parent directory name)
#   --license=LICENSE      License identifier (default: inferred by gen-manifest)
#   --www=URL              Project URL (default: source tree's git remote)
#   --comment=COMMENT      Short description (default: README first line, trimmed)
#   --desc=DESC            Long description (default: README first line)
#   --maintainer=NAME      Package maintainer (default: git config user.name/email)
#   --prefix-root=PATH     Install root (default: /opt/xnuports)
#   --build-system=SYS     Force: go, cargo, cmake, meson, autotools, bmake, make
#   --output=DIR           Where to write the .pkg (default: <repo>/staging)
#   --jobs=N               Parallel build jobs (default: CPU count)
#   --publish              Copy into the repo and regenerate its metadata
#   --keep-work            Keep the temporary build directory
#   --dry-run              Show what would be done without building
#   --help                 Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PACKAGE_SH="${SCRIPT_DIR}/package.sh"

SRC_DIR=""
NAME=""
VERSION=""
CATEGORY=""
LICENSE=""
WWW=""
COMMENT=""
DESC=""
MAINTAINER=""
PREFIX_ROOT="/opt/xnuports"
BUILD_SYSTEM="auto"
OUTPUT_DIR=""
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
PUBLISH=0
KEEP_WORK=0
DRY_RUN=0

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
  exit 0
}

die() { echo "Error: $*" >&2; exit 1; }
# Manifest values are UCL strings: tabs and other control characters make
# 'pkg create' fail with a parsing error. README first lines often carry them.
sanitize() { echo "$*" | tr '\t\n\r' '   ' | sed 's/^ *//; s/ *$//; s/  */ /g'; }
step() { echo; echo "=== $* ==="; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage ;;
    --name=*) NAME="${1#*=}"; shift ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --category=*) CATEGORY="${1#*=}"; shift ;;
    --license=*) LICENSE="${1#*=}"; shift ;;
    --www=*) WWW="${1#*=}"; shift ;;
    --comment=*) COMMENT="${1#*=}"; shift ;;
    --desc=*) DESC="${1#*=}"; shift ;;
    --maintainer=*) MAINTAINER="${1#*=}"; shift ;;
    --prefix-root=*) PREFIX_ROOT="${1#*=}"; shift ;;
    --build-system=*) BUILD_SYSTEM="${1#*=}"; shift ;;
    --output=*) OUTPUT_DIR="${1#*=}"; shift ;;
    --jobs=*) JOBS="${1#*=}"; shift ;;
    --publish) PUBLISH=1; shift ;;
    --keep-work) KEEP_WORK=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -*) die "Unknown option: $1" ;;
    *)
      [[ -z "${SRC_DIR}" ]] || die "unexpected argument: $1"
      SRC_DIR="$1"; shift ;;
  esac
done

[[ -n "${SRC_DIR}" ]] || { echo "Error: source directory required" >&2; usage; }
[[ -d "${SRC_DIR}" ]] || die "directory not found: ${SRC_DIR}"
SRC_DIR="$(cd "${SRC_DIR}" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/staging}"

# ─── Identity ────────────────────────────────────────────────────────────────

dir_name="$(basename "${SRC_DIR}")"
if [[ -z "${NAME}" || -z "${VERSION}" ]]; then
  if [[ "${dir_name}" =~ ^(.+)-([0-9]+\.[0-9]+[^/]*)$ ]]; then
    NAME="${NAME:-${BASH_REMATCH[1]}}"
    VERSION="${VERSION:-${BASH_REMATCH[2]}}"
  else
    NAME="${NAME:-${dir_name}}"
  fi
fi

if [[ -z "${VERSION}" ]]; then
  # git tag, then a VERSION file, then give up and ask
  tag="$(git -C "${SRC_DIR}" describe --tags --abbrev=0 2>/dev/null || true)"
  if [[ -n "${tag}" ]]; then
    VERSION="${tag#v}"
  elif [[ -f "${SRC_DIR}/VERSION" ]]; then
    VERSION="$(grep -oE '[0-9]+(\.[0-9]+)+' "${SRC_DIR}/VERSION" | head -1 || true)"
  fi
fi
[[ -n "${VERSION}" ]] || die "could not infer version for ${NAME}; pass --version=X.Y.Z"

# Category defaults to the parent directory (games/wizardry -> games)
if [[ -z "${CATEGORY}" ]]; then
  parent="$(basename "$(dirname "${SRC_DIR}")")"
  [[ "${parent}" != "staging" && "${parent}" != "/" ]] && CATEGORY="${parent}"
fi
[[ -n "${CATEGORY}" ]] || die "could not infer category; pass --category=CAT"

# Maintainer is whoever maintains the PACKAGE, not the upstream author.
# Upstream attribution belongs in www and the project's own license file.
if [[ -z "${MAINTAINER}" ]]; then
  git_name="$(git -C "${REPO_ROOT}" config user.name 2>/dev/null || true)"
  git_email="$(git -C "${REPO_ROOT}" config user.email 2>/dev/null || true)"
  [[ -n "${git_name}" && -n "${git_email}" ]] && MAINTAINER="${git_name} <${git_email}>"
fi

# www comes from the SOURCE tree's remote, not the staged copy (which is not a
# git checkout, so gen-manifest would fall back to a guessed xnuports URL).
if [[ -z "${WWW}" ]]; then
  remote="$(git -C "${SRC_DIR}" remote get-url origin 2>/dev/null || true)"
  if [[ -n "${remote}" ]]; then
    remote="${remote%.git}"
    remote="${remote#git@}"
    remote="${remote#https://}"
    remote="${remote#ssh://}"
    WWW="https://${remote/://}"
  fi
fi

# comment is a one-line summary; desc carries the full text. gen-manifest uses
# the README's first line for both, which yields a 175-character "comment".
readme=""
for f in README.md README README.rst; do
  [[ -f "${SRC_DIR}/${f}" ]] && { readme="${SRC_DIR}/${f}"; break; }
done
if [[ -n "${readme}" && ( -z "${COMMENT}" || -z "${DESC}" ) ]]; then
  first="$(sanitize "$(sed '/^#/d; /^$/d; /^\[!\[/d' "${readme}" | head -1)")"
  DESC="${DESC:-${first}}"
  if [[ -z "${COMMENT}" ]]; then
    COMMENT="${first%%.*}"                       # first sentence
    if [[ "${#COMMENT}" -gt 70 ]]; then
      COMMENT="$(echo "${COMMENT}" | cut -c1-70 | sed 's/ [^ ]*$//')"
    fi
  fi
fi

COMMENT="$(sanitize "${COMMENT}")"
DESC="$(sanitize "${DESC}")"

PREFIX="${PREFIX_ROOT}/opt/${NAME}"

# ─── Build system detection ──────────────────────────────────────────────────

detect_build_system() {
  # bmake is checked first: it ships a boot-strap script and needs its default
  # sys.mk search path set explicitly, which the generic autotools path cannot do.
  if [[ -x "${SRC_DIR}/boot-strap" && -f "${SRC_DIR}/VERSION" ]] &&
     grep -q '_MAKE_VERSION' "${SRC_DIR}/VERSION" 2>/dev/null; then
    echo bmake; return
  fi
  # go.mod outranks a hand-written Makefile: the Makefile usually wraps a plain
  # 'go build' with no -trimpath, which leaves build paths in the binary.
  [[ -f "${SRC_DIR}/go.mod" ]] && { echo go; return; }
  [[ -f "${SRC_DIR}/Cargo.toml" ]] && { echo cargo; return; }
  [[ -f "${SRC_DIR}/CMakeLists.txt" ]] && { echo cmake; return; }
  [[ -f "${SRC_DIR}/meson.build" ]] && { echo meson; return; }
  [[ -f "${SRC_DIR}/configure" || -f "${SRC_DIR}/configure.ac" || -f "${SRC_DIR}/configure.in" ]] && { echo autotools; return; }
  [[ -f "${SRC_DIR}/Makefile" || -f "${SRC_DIR}/makefile" ]] && { echo make; return; }
  echo unknown
}

[[ "${BUILD_SYSTEM}" == "auto" ]] && BUILD_SYSTEM="$(detect_build_system)"
[[ "${BUILD_SYSTEM}" != "unknown" ]] || die "could not detect a build system in ${SRC_DIR}; pass --build-system=SYS"

echo "=== xnuports build-package ==="
echo "  Source:       ${SRC_DIR}"
echo "  Build system: ${BUILD_SYSTEM}"
echo "  Name:         ${NAME}"
echo "  Version:      ${VERSION}"
echo "  Category:     ${CATEGORY}"
echo "  Prefix:       ${PREFIX}"
echo "  Maintainer:   ${MAINTAINER:-<unset>}"
echo "  WWW:          ${WWW:-<unset>}"
echo "  Comment:      ${COMMENT:-<unset>}"
echo "  Output:       ${OUTPUT_DIR}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo
  echo "Dry run: would build with the ${BUILD_SYSTEM} recipe and package to ${OUTPUT_DIR}/${NAME}-${VERSION}.pkg"
  exit 0
fi

WORK="$(mktemp -d -t xnuports-build)"
cleanup() {
  if [[ "${KEEP_WORK}" -eq 1 ]]; then
    echo "Work directory kept: ${WORK}"
  else
    rm -rf "${WORK}"
  fi
}
trap cleanup EXIT

DESTDIR="${WORK}/dest"
mkdir -p "${DESTDIR}"

# Copy the source for build systems that build in-tree, so the user's checkout
# is never polluted with objects or generated configure output.
# The copy keeps the source directory's own name. Some build systems key off
# it: bmake's boot-strap locates its source tree by searching for a path
# containing "/bmake", and silently prints usage if it cannot find one.
copy_source() {
  local dest="${WORK}/$(basename "${SRC_DIR}")"
  mkdir -p "${dest}"
  (cd "${SRC_DIR}" && tar cf - --exclude='.git' .) | (cd "${dest}" && tar xf -)
  echo "${dest}"
}

# ─── Build recipes ───────────────────────────────────────────────────────────

build_go() {
  step "Building with go (-trimpath)"
  mkdir -p "${DESTDIR}${PREFIX}/bin"
  # -trimpath removes absolute source paths from the binary's debug info.
  # Without it a Go binary carries the full build-time path of every file.
  if [[ -d "${SRC_DIR}/cmd" ]]; then
    for d in "${SRC_DIR}"/cmd/*/; do
      [[ -d "${d}" ]] || continue
      local bin; bin="$(basename "${d}")"
      echo "  go build -trimpath -o bin/${bin} ./cmd/${bin}"
      (cd "${SRC_DIR}" && go build -trimpath -o "${DESTDIR}${PREFIX}/bin/${bin}" "./cmd/${bin}")
    done
  else
    echo "  go build -trimpath -o bin/${NAME} ."
    (cd "${SRC_DIR}" && go build -trimpath -o "${DESTDIR}${PREFIX}/bin/${NAME}" .)
  fi
}

build_cargo() {
  step "Building with cargo (--release, remapped paths)"
  local target="${WORK}/cargo-target"
  (cd "${SRC_DIR}" && \
    RUSTFLAGS="--remap-path-prefix=${SRC_DIR}=. ${RUSTFLAGS:-}" \
    cargo build --release --target-dir "${target}" -j "${JOBS}")
  mkdir -p "${DESTDIR}${PREFIX}/bin"
  find "${target}/release" -maxdepth 1 -type f -perm -u+x ! -name '*.d' ! -name '*.rlib' \
    -exec cp {} "${DESTDIR}${PREFIX}/bin/" \;
}

build_cmake() {
  step "Building with cmake (prefix=${PREFIX}, staged via DESTDIR)"
  cmake -S "${SRC_DIR}" -B "${WORK}/cmake-build" \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" -DCMAKE_BUILD_TYPE=Release
  cmake --build "${WORK}/cmake-build" -j "${JOBS}"
  DESTDIR="${DESTDIR}" cmake --install "${WORK}/cmake-build"
}

build_meson() {
  step "Building with meson (prefix=${PREFIX}, staged via DESTDIR)"
  meson setup "${WORK}/meson-build" "${SRC_DIR}" --prefix="${PREFIX}" --buildtype=release
  meson compile -C "${WORK}/meson-build" -j "${JOBS}"
  DESTDIR="${DESTDIR}" meson install -C "${WORK}/meson-build"
}

build_autotools() {
  step "Building with autotools (prefix=${PREFIX}, staged via DESTDIR)"
  local src; src="$(copy_source)"
  cd "${src}"
  if [[ ! -f configure ]]; then
    if [[ -x ./autogen.sh ]]; then ./autogen.sh
    else autoreconf -i; fi
  fi
  ./configure --prefix="${PREFIX}"
  make -j"${JOBS}"
  make install DESTDIR="${DESTDIR}"
}

build_bmake() {
  step "Building with bmake boot-strap (explicit sys.mk path)"
  local src; src="$(copy_source)"
  # The default sys.mk search path must point at the installed location, not at
  # wherever this build happens. Two entries so it resolves through the
  # pkg-symlink farm and still works if that farm is incomplete.
  (cd "${src}" && SKIP_RC=1 ./boot-strap \
    --prefix="${PREFIX}" \
    --install-destdir="${DESTDIR}" \
    --with-default-sys-path="${PREFIX_ROOT}/share/mk:${PREFIX}/share/mk" \
    -o "${WORK}/bmake-obj" \
    op=install)
}

build_make() {
  step "Building with make (PREFIX=${PREFIX}, staged via DESTDIR)"
  local src; src="$(copy_source)"
  cd "${src}"
  make -j"${JOBS}" PREFIX="${PREFIX}"
  grep -qE '^install:' Makefile makefile 2>/dev/null || die "no 'install' target in Makefile; build this one manually"
  make install PREFIX="${PREFIX}" DESTDIR="${DESTDIR}"
}

case "${BUILD_SYSTEM}" in
  go) build_go ;;
  cargo) build_cargo ;;
  cmake) build_cmake ;;
  meson) build_meson ;;
  autotools) build_autotools ;;
  bmake) build_bmake ;;
  make) build_make ;;
  *) die "unsupported build system: ${BUILD_SYSTEM}" ;;
esac

# ─── Stage ───────────────────────────────────────────────────────────────────

STAGED="${DESTDIR}${PREFIX}"
SYSTEM_LAYOUT=0
if [[ ! -d "${STAGED}" ]]; then
  # Base-system ports (xcode-tools) install to absolute paths (/etc, /usr/bin,
  # /Applications/...) and can never live under the runtime prefix. If DESTDIR
  # was honoured but nothing landed under PREFIX, package the whole tree with
  # prefix=/ rather than failing.
  if [[ -z "$(find "${DESTDIR}" -type f -print -quit)" ]]; then
    die "build produced nothing at ${STAGED} nor anywhere under ${DESTDIR}; the install step may not honour DESTDIR"
  fi
  SYSTEM_LAYOUT=1
  step "System-layout install detected"
  echo "  Nothing installed under ${PREFIX}, but DESTDIR has content."
  echo "  Staging the full DESTDIR tree; manifest prefix will be /."
fi

# package.sh takes the package name and version from the directory name.
STAGE="${WORK}/${NAME}-${VERSION}"
if [[ "${SYSTEM_LAYOUT}" -eq 1 ]]; then
  mv "${DESTDIR}" "${STAGE}"
else
  mv "${STAGED}" "${STAGE}"
  # Mixed installs silently lose everything outside PREFIX — say so loudly.
  if [[ -n "$(find "${DESTDIR}" -mindepth 1 -print -quit)" ]]; then
    echo "  Warning: files were also installed outside ${PREFIX} and are NOT packaged:" >&2
    find "${DESTDIR}" -mindepth 1 -maxdepth 3 | sed 's/^/    /' >&2
  fi
fi

# gen-manifest.sh enumerates files with 'find -type f', so any symlink in the
# staged tree would be dropped from the package without warning. Materialise
# them as regular files. bmake's 13 bsd.*.mk compatibility links are exactly
# this case: without it the package silently ships 88 files instead of 101.
link_count=0
while IFS= read -r link; do
  [[ -n "${link}" ]] || continue
  if [[ -e "${link}" ]]; then
    cp -L "${link}" "${link}.__deref" && mv -f "${link}.__deref" "${link}"
    link_count=$((link_count + 1))
  else
    # Dangling on disk, but the target may live inside the staged tree
    # (system-layout ports symlink by absolute path, e.g. clang++ -> /Applications/...).
    target="$(readlink "${link}")"
    if [[ "${target}" == /* && -f "${STAGE}${target}" ]]; then
      rm -f "${link}" && cp "${STAGE}${target}" "${link}"
      link_count=$((link_count + 1))
    else
      echo "  Warning: dropping dangling symlink $(basename "${link}")" >&2
      rm -f "${link}"
    fi
  fi
done < <(find "${STAGE}" -type l)
[[ "${link_count}" -gt 0 ]] && echo "  Materialised ${link_count} symlink(s) as regular files"

# Match the layout of the existing packages: license and readme at the root.
for f in LICENSE LICENCE COPYING README README.md VERSION +POST-INSTALL; do
  [[ -f "${SRC_DIR}/${f}" && ! -e "${STAGE}/${f}" ]] && cp "${SRC_DIR}/${f}" "${STAGE}/"
done

step "Staged tree"
echo "  ${STAGE}"
echo "  $(find "${STAGE}" -type f | wc -l | tr -d ' ') files, $(du -sh "${STAGE}" | cut -f1)"

# ─── Package ─────────────────────────────────────────────────────────────────

PKG_ARGS=("${STAGE}" "--category=${CATEGORY}" "--version=${VERSION}" "--output=${OUTPUT_DIR}")
[[ "${SYSTEM_LAYOUT}" -eq 1 ]] && PKG_ARGS+=("--prefix=/")
[[ -n "${LICENSE}" ]] && PKG_ARGS+=("--license=${LICENSE}")
[[ -n "${WWW}" ]] && PKG_ARGS+=("--www=${WWW}")
[[ -n "${COMMENT}" ]] && PKG_ARGS+=("--comment=${COMMENT}")
[[ -n "${DESC}" ]] && PKG_ARGS+=("--desc=${DESC}")
[[ -n "${MAINTAINER}" ]] && PKG_ARGS+=("--maintainer=${MAINTAINER}")

mkdir -p "${OUTPUT_DIR}"
"${PACKAGE_SH}" "${PKG_ARGS[@]}"

PKG_FILE="${OUTPUT_DIR}/${NAME}-${VERSION}.pkg"

# ─── Publish (optional) ──────────────────────────────────────────────────────

if [[ "${PUBLISH}" -eq 1 ]]; then
  arch_dir="${REPO_ROOT}/packages/macOS-$(uname -m)/latest"
  [[ -d "${arch_dir}/packages" ]] || die "repository not found: ${arch_dir}/packages"
  step "Publishing to ${arch_dir}"
  # Drop older builds of this package so the repo carries one version.
  find "${arch_dir}/packages" -maxdepth 1 -name "${NAME}-*.pkg" ! -name "$(basename "${PKG_FILE}")" -delete
  cp "${PKG_FILE}" "${arch_dir}/packages/"
  "${SCRIPT_DIR}/update-repo-metadata.sh" "${arch_dir}"
fi

echo
echo "Done: ${PKG_FILE}"
