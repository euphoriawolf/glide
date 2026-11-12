#!/bin/bash
# Build Glide.app in build/.
# With .signing/ (from setup-signing.sh) the app gets a stable signature.
# Without it the app is signed ad hoc, and macOS asks for Accessibility after each build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Glide

APP=build/Glide.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Glide "$APP/Contents/MacOS/Glide"
cp Resources/Info.plist "$APP/Contents/Info.plist"

KC="$PWD/.signing/glide.keychain-db"
if [ -f "$KC" ]; then
  security unlock-keychain -p "$(cat .signing/password)" "$KC"
  HASH=$(security find-identity -p codesigning "$KC" | awk '/Glide Local Signing/{print $2; exit}')
  # codesign finds the identity only through the search list. Add the keychain, sign, then restore the list.
  OLD_LIST=$(security list-keychains -d user | sed 's/^ *"//; s/"$//')
  # shellcheck disable=SC2086
  trap 'security list-keychains -d user -s $OLD_LIST' EXIT
  # shellcheck disable=SC2086
  security list-keychains -d user -s $OLD_LIST "$KC"
  codesign --force --sign "$HASH" "$APP"
else
  codesign --force --sign - "$APP"
fi

echo "$APP"
