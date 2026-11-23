#!/bin/sh
# Signs DBooyvol.app with a "Developer ID Application" certificate from the login keychain.
# Usage: ./scripts/sign.sh [path-to-app] ["Developer ID Application: Name (TEAMID)"]
set -e
APP=${1:-build/Build/Products/Release/DBooyvol.app}

if [ ! -d "$APP" ]; then
  echo "App not found: $APP"
  echo "Build Release first: xcodebuild -project DBooyvol.xcodeproj -scheme DBooyvol -configuration Release -derivedDataPath build build"
  exit 1
fi

IDENTITY=${2:-}
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)
fi

if [ -z "$IDENTITY" ]; then
  echo "No 'Developer ID Application' identity found."
  echo "Install the certificate for silver.johnes@gmail.com in Keychain Access, then retry."
  echo "Temporary ad-hoc signing: codesign --force --deep --sign - \"$APP\""
  exit 1
fi

echo "Signing with: $IDENTITY"
codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo
echo "Done. For notarization:"
echo "  xcrun notarytool submit \"$APP\" --apple-id silver.johnes@gmail.com --team-id <TEAMID> --password <app-specific-password> --wait"
echo "  xcrun stapler staple \"$APP\""
