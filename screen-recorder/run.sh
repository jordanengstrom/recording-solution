#!/bin/bash

set -euo pipefail

INSTALLED_APP="${HOME}/Applications/ScreenRecorder.app"

if [[ ! -d "${INSTALLED_APP}" ]]; then
    echo "Screen Recorder is not installed. Run ./install.sh first." >&2
    exit 1
fi

open "${INSTALLED_APP}"

