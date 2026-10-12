#!/bin/bash
# Builds build/Pinna.app. Set SIGN_IDENTITY to sign with your own certificate
# (otherwise it's ad-hoc signed, and macOS asks for Screen Recording again after each rebuild).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Pinna"

APP="build/Pinna.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Pinna"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

echo "Built $APP"
