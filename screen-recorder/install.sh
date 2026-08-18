#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_APP="${PROJECT_DIR}/build/ScreenRecorder.app"
INSTALL_DIR="${HOME}/Applications"
INSTALLED_APP="${INSTALL_DIR}/ScreenRecorder.app"
BACKUP_APP="${INSTALL_DIR}/.ScreenRecorder.app.previous"

if pgrep -f "${INSTALLED_APP}/Contents/MacOS/ScreenRecorder" >/dev/null 2>&1; then
    echo "Quit the installed Screen Recorder before reinstalling it." >&2
    exit 1
fi

"${PROJECT_DIR}/build.sh"
mkdir -p "${INSTALL_DIR}"

rm -rf "${BACKUP_APP}"
if [[ -e "${INSTALLED_APP}" ]]; then
    mv "${INSTALLED_APP}" "${BACKUP_APP}"
fi

if ! ditto "${SOURCE_APP}" "${INSTALLED_APP}"; then
    rm -rf "${INSTALLED_APP}"
    if [[ -e "${BACKUP_APP}" ]]; then
        mv "${BACKUP_APP}" "${INSTALLED_APP}"
    fi
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "${INSTALLED_APP}"
rm -rf "${BACKUP_APP}"

echo "Installed ${INSTALLED_APP}"

