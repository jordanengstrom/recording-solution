#!/bin/bash

set -euo pipefail

if [[ ! -t 0 ]]; then
    echo "Run this script in an interactive Terminal." >&2
    exit 1
fi

echo "This removes the existing Screen Recording permission for"
echo "com.jordan.screenrecorder so macOS can register the newly signed app."
read -r -p "Type RESET to continue: " confirmation

if [[ "${confirmation}" != "RESET" ]]; then
    echo "Cancelled."
    exit 0
fi

tccutil reset ScreenCapture com.jordan.screenrecorder
echo "Permission reset. Run ./run.sh and click Start Recording to grant it again."

