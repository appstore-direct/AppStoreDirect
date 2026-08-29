#!/bin/bash
# Builds the Go sidecar that speaks Apple's App Store protocol.
# Invoked by Xcode before compiling the app, and usable on its own.
#
#   ./Scripts/build-bridge.sh            build for this Mac
#   ./Scripts/build-bridge.sh universal  build a universal binary for distribution
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${ROOT}/.build/appstore-bridge"
MODE="${1:-native}"

if ! command -v go >/dev/null 2>&1; then
    echo "error: Go is required to build the App Store bridge (brew install go)" >&2
    exit 1
fi

mkdir -p "${ROOT}/.build"
cd "${ROOT}/bridge"

# cgo stays enabled: a transitive dependency of ipatool's keychain package does not
# compile without it. The sidecar does not itself use cgo.
FLAGS=(-trimpath -ldflags "-s -w")

if [ "${MODE}" = "universal" ]; then
    # Distribution builds cover both architectures. Cross-compiling with cgo needs
    # the matching clang target, which Xcode's toolchain provides.
    CGO_ENABLED=1 GOARCH=arm64 CC="clang -arch arm64" \
        go build "${FLAGS[@]}" -o "${OUTPUT}.arm64" .
    CGO_ENABLED=1 GOARCH=amd64 CC="clang -arch x86_64" \
        go build "${FLAGS[@]}" -o "${OUTPUT}.amd64" .
    lipo -create -output "${OUTPUT}" "${OUTPUT}.arm64" "${OUTPUT}.amd64"
    rm -f "${OUTPUT}.arm64" "${OUTPUT}.amd64"
else
    go build "${FLAGS[@]}" -o "${OUTPUT}" .
fi

echo "built ${OUTPUT} ($(lipo -archs "${OUTPUT}" 2>/dev/null || echo native))"
