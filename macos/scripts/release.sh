#!/bin/bash
# Builds a universal "Floorspace.app" and packages it for a GitHub release:
#   dist/Floorspace-<version>.dmg  (drag-to-Applications disk image)
#   dist/Floorspace-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" AppBundle/Info.plist)
APP="build/Floorspace.app"
DIST="dist"

./scripts/build-app.sh --universal
codesign --verify --strict "$APP"

rm -rf "$DIST"
mkdir -p "$DIST"

# ditto keeps the code signature and extended attributes intact.
ditto -c -k --keepParent "$APP" "$DIST/Floorspace-$VERSION.zip"

STAGING=$(mktemp -d)
ditto "$APP" "$STAGING/Floorspace.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Floorspace $VERSION" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DIST/Floorspace-$VERSION.dmg"
rm -rf "$STAGING"

(cd "$DIST" && shasum -a 256 Floorspace-* > SHA256SUMS.txt)
echo "Release files for $VERSION:"
ls -lh "$DIST"
