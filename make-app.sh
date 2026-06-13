#!/bin/bash
# Build OpenRecorder.app from the SwiftPM executable.
# TCC (Screen Recording / Microphone) requires a signed .app bundle on
# macOS 15+; bare executables won't even appear in System Settings.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="OpenRecorder.app"

swift build -c "$CONFIG"

BIN=".build/$CONFIG/OpenRecorder"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OpenRecorder"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature is enough for local TCC; replace with a Developer ID
# identity for distribution.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
echo "Run:  open $APP"
echo "First run downloads Whisper models (~150MB live + ~1.6GB offline) from HuggingFace."
