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

# Sign with a stable self-signed identity if present, so macOS TCC grants
# (Screen Recording / Microphone) persist across rebuilds. Falls back to
# ad-hoc (re-prompts every rebuild). Create the identity with:
#   ./make-signing-cert.sh
SIGN_ID="OpenRecorder Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    codesign --force --deep --sign "$SIGN_ID" "$APP"
    echo "signed with stable identity: $SIGN_ID"
else
    codesign --force --deep --sign - "$APP"
    echo "signed ad-hoc (TCC will re-prompt each rebuild — run ./make-signing-cert.sh to fix)"
fi

echo "Built $APP"
echo "Run:  open $APP"
echo "First run downloads Whisper models (~150MB live + ~1.6GB offline) from HuggingFace."
