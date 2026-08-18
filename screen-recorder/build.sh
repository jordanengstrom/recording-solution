#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
APP_DIR="${BUILD_DIR}/ScreenRecorder.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
MODULE_CACHE_DIR="/private/tmp/com.jordan.screenrecorder-module-cache"
IDENTITY_NAME="Screen Recorder Local Signing"

IDENTITY_HASHES="$(
    security find-identity -v -p codesigning 2>/dev/null \
        | awk -v target="\"${IDENTITY_NAME}\"" 'index($0, target) { print $2 }'
)"
IDENTITY_COUNT="$(printf '%s\n' "${IDENTITY_HASHES}" | awk 'NF { count += 1 } END { print count + 0 }')"

if [[ "${IDENTITY_COUNT}" -eq 0 ]]; then
    echo "Missing local code-signing identity: ${IDENTITY_NAME}" >&2
    echo "Run ./setup-local-signing.sh once, then rebuild." >&2
    exit 1
fi

if [[ "${IDENTITY_COUNT}" -gt 1 ]]; then
    echo "Multiple '${IDENTITY_NAME}' identities were found." >&2
    echo "Remove duplicates in Keychain Access before rebuilding." >&2
    exit 1
fi

SIGNING_IDENTITY="${IDENTITY_HASHES}"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${MODULE_CACHE_DIR}"

xcrun swiftc \
    -parse-as-library \
    -target arm64-apple-macosx15.0 \
    -O \
    -module-cache-path "${MODULE_CACHE_DIR}" \
    -framework AppKit \
    -framework AVFoundation \
    -framework CoreGraphics \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework QuartzCore \
    -framework ScreenCaptureKit \
    -framework SwiftUI \
    "${PROJECT_DIR}"/Sources/*.swift \
    -o "${MACOS_DIR}/ScreenRecorder"

cp "${PROJECT_DIR}/Info.plist" "${CONTENTS_DIR}/Info.plist"
codesign \
    --force \
    --sign "${SIGNING_IDENTITY}" \
    --identifier com.jordan.screenrecorder \
    --timestamp=none \
    "${APP_DIR}"

codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

DESIGNATED_REQUIREMENT="$(codesign -dr - "${APP_DIR}" 2>&1)"
if [[ "${DESIGNATED_REQUIREMENT}" == *"cdhash"* ]]; then
    echo "Signing failed: the designated requirement is still tied to a binary hash." >&2
    exit 1
fi
if [[ "${DESIGNATED_REQUIREMENT}" != *'identifier "com.jordan.screenrecorder"'* ]]; then
    echo "Signing failed: the designated requirement has the wrong identifier." >&2
    exit 1
fi

echo "Built ${APP_DIR}"
echo "${DESIGNATED_REQUIREMENT}"
