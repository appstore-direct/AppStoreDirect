#!/bin/bash
# Builds a standalone AppStoreDirect.app and installs it to /Applications.
#
# The point of this script is self-containment. A plain Xcode build links
# Homebrew's libimobiledevice by absolute path, so the app breaks the moment
# Homebrew is updated, relocated or removed. Here the six dylibs it needs are
# copied into Contents/Frameworks and their install names rewritten to @rpath, so
# the finished app depends on nothing outside itself and macOS.
#
#   ./Scripts/package.sh            build, bundle, sign, install to /Applications
#   ./Scripts/package.sh --no-install   leave the result in build/ instead
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="Release"
STAGE="${ROOT}/build"
INSTALL_DIR="/Applications"
DO_INSTALL=1
[ "${1:-}" = "--no-install" ] && DO_INSTALL=0

# Signing identity, same source of truth as the Xcode build.
IDENTITY="$(awk -F' = ' '/^ASD_SIGN_IDENTITY/ {print $2}' "${ROOT}/Signing.xcconfig" | tr -d ' ')"
IDENTITY="${IDENTITY:--}"

echo "==> Building the App Store bridge"
"${ROOT}/Scripts/build-bridge.sh" >/dev/null

echo "==> Generating the Xcode project"
(cd "${ROOT}" && xcodegen generate >/dev/null)

echo "==> Building ${CONFIG}"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"
xcodebuild \
    -project "${ROOT}/AppStoreDirect.xcodeproj" \
    -scheme AppStoreDirect \
    -configuration "${CONFIG}" \
    -destination 'platform=macOS' \
    CONFIGURATION_BUILD_DIR="${STAGE}" \
    build >/dev/null

APP="${STAGE}/AppStoreDirect.app"
[ -d "${APP}" ] || { echo "error: build produced no app bundle" >&2; exit 1; }

FRAMEWORKS="${APP}/Contents/Frameworks"
mkdir -p "${FRAMEWORKS}"

# The transitive closure of what libimobiledevice needs. Resolved from the live
# Homebrew install rather than hardcoded versions, so a Homebrew upgrade is picked
# up the next time this script runs.
#
# Written for bash 3.2, the version macOS ships: no associative arrays, no mapfile.
echo "==> Bundling libraries"

EXTERNAL='^/opt/homebrew|^/usr/local/(opt|lib)'
DEPS="$(mktemp)"
trap 'rm -f "${DEPS}" "${DEPS}.next"' EXIT

# Direct dependencies of a binary, resolved through symlinks to real files.
# Returns nothing, successfully, when a binary has no external dependencies —
# grep's "no match" exit status must not abort the script under `set -e`.
direct_dependencies() {
    otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}' \
        | { grep -E "${EXTERNAL}" || true; } \
        | while read -r path; do
            real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${path}" 2>/dev/null || true)"
            [ -n "${real}" ] && [ -f "${real}" ] && echo "${real}"
        done
    return 0
}

# Seed from every executable in the bundle.
find "${APP}/Contents/MacOS" -type f -perm +111 | while read -r binary; do
    direct_dependencies "${binary}"
done | sort -u > "${DEPS}"

# Expand to a fixed point: each round adds the dependencies of what we already have.
while :; do
    before="$(wc -l < "${DEPS}" | tr -d ' ')"
    cat "${DEPS}" > "${DEPS}.next"
    while read -r lib; do
        direct_dependencies "${lib}" >> "${DEPS}.next"
    done < "${DEPS}"
    sort -u "${DEPS}.next" -o "${DEPS}"
    after="$(wc -l < "${DEPS}" | tr -d ' ')"
    [ "${before}" = "${after}" ] && break
done

while read -r lib; do
    [ -n "${lib}" ] || continue
    base="$(basename "${lib}")"
    cp -f "${lib}" "${FRAMEWORKS}/${base}"
    chmod 644 "${FRAMEWORKS}/${base}"
    echo "    ${base}"
done < "${DEPS}"

echo "==> Rewriting load paths"
# Each bundled dylib gets an @rpath identity, and every reference to a Homebrew
# path — in the app binaries and between the dylibs themselves — is repointed.
for lib in "${FRAMEWORKS}"/*.dylib; do
    [ -f "${lib}" ] || continue
    install_name_tool -id "@rpath/$(basename "${lib}")" "${lib}" 2>/dev/null || true
done

repoint() {
    local target="$1"
    otool -L "${target}" 2>/dev/null | tail -n +2 | awk '{print $1}' \
        | { grep -E "${EXTERNAL}" || true; } | while read -r old; do
        local base
        base="$(basename "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${old}" 2>/dev/null || echo "${old}")")"
        [ -f "${FRAMEWORKS}/${base}" ] || continue
        install_name_tool -change "${old}" "@rpath/${base}" "${target}" 2>/dev/null || true
    done
}

for lib in "${FRAMEWORKS}"/*.dylib; do
    [ -f "${lib}" ] && repoint "${lib}"
done
find "${APP}/Contents/MacOS" -type f -perm +111 | while read -r binary; do
    repoint "${binary}"
done

echo "==> Signing"
# Inside out: dylibs, then the helper, then the bundle itself. The helper is
# copied in after Xcode signs, so without this the bundle fails --deep --strict.
for lib in "${FRAMEWORKS}"/*.dylib; do
    [ -f "${lib}" ] && codesign --force --options runtime --sign "${IDENTITY}" "${lib}" 2>/dev/null
done
[ -f "${APP}/Contents/MacOS/appstore-bridge" ] && \
    codesign --force --options runtime --sign "${IDENTITY}" "${APP}/Contents/MacOS/appstore-bridge" 2>/dev/null
codesign --force --options runtime \
    --entitlements "${ROOT}/App/AppStoreDirect.entitlements" \
    --sign "${IDENTITY}" "${APP}" 2>/dev/null

codesign --verify --deep --strict "${APP}"
echo "    signature valid"

echo "==> Checking self-containment"
LEAKED="$(find "${APP}" -type f -perm +111 -exec otool -L {} \; 2>/dev/null \
    | { grep -E '^[[:space:]]+/opt/homebrew|^[[:space:]]+/usr/local/(opt|lib)' || true; } | sort -u)"
if [ -n "${LEAKED}" ]; then
    echo "error: the bundle still references libraries outside itself:" >&2
    echo "${LEAKED}" >&2
    exit 1
fi
echo "    no external library references"

if [ ${DO_INSTALL} -eq 1 ]; then
    echo "==> Installing to ${INSTALL_DIR}"
    pkill -f "${INSTALL_DIR}/AppStoreDirect.app" 2>/dev/null || true
    sleep 1
    rm -rf "${INSTALL_DIR}/AppStoreDirect.app"
    ditto "${APP}" "${INSTALL_DIR}/AppStoreDirect.app"
    echo "    ${INSTALL_DIR}/AppStoreDirect.app"
else
    echo "==> Left at ${APP}"
fi

echo
echo "Done."
