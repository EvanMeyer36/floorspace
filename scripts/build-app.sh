#!/bin/bash
# Builds "Mac Cleaner.app" into ./build. Pass --install to also copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Mac Cleaner.app"

if [[ ! -f AppBundle/AppIcon.icns ]]; then
    swift scripts/make-icon.swift
fi

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacCleaner" "$APP/Contents/MacOS/MacCleaner"
cp AppBundle/Info.plist "$APP/Contents/Info.plist"
cp AppBundle/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so macOS will run it locally. (Not notarized: for this Mac only.)
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/Mac Cleaner.app"
    ditto "$APP" "/Applications/Mac Cleaner.app"
    echo "Installed to /Applications/Mac Cleaner.app"
fi
