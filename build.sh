#!/bin/bash
# Builds build/Pinna.app. Options, as environment variables:
#   SIGN_IDENTITY="Developer ID Application: …"  Sign with your own certificate, with the hardened runtime.
#                       Otherwise it's ad-hoc signed, and macOS asks for Screen Recording again after each rebuild.
#   UNIVERSAL=1         Build for both Apple silicon and Intel Macs.
#   NOTARY_PROFILE=…    Notarize with Apple and staple the ticket, using a profile saved with
#                       `xcrun notarytool store-credentials`. Needs a Developer ID SIGN_IDENTITY.
#   DMG=1               Also make build/Pinna.dmg, for sharing.
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=()
if [[ "${UNIVERSAL:-}" == 1 ]]; then
    ARCHS=(--arch arm64 --arch x86_64)
fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Pinna"

APP="build/Pinna.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pinna"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

sign() {
    if [[ -n "${SIGN_IDENTITY:-}" ]]; then
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$1"
    else
        codesign --force --sign - "$1"
    fi
}

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

sign "$APP"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    ditto -c -k --keepParent "$APP" build/Pinna.zip
    notarize build/Pinna.zip
    rm build/Pinna.zip
    xcrun stapler staple "$APP"
fi
echo "Built $APP"

if [[ "${DMG:-}" == 1 ]]; then
    STAGING="$(mktemp -d)"
    cp -R "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    rm -f build/Pinna.dmg
    hdiutil create -quiet -volname Pinna -srcfolder "$STAGING" -format UDZO build/Pinna.dmg
    rm -rf "$STAGING"
    if [[ -n "${SIGN_IDENTITY:-}" ]]; then
        codesign --force --timestamp --sign "$SIGN_IDENTITY" build/Pinna.dmg
    fi
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        notarize build/Pinna.dmg
        xcrun stapler staple build/Pinna.dmg
    fi
    echo "Built build/Pinna.dmg"
fi
