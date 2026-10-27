#!/bin/bash
# Builds "Mac Cleaner.app" into ./build.
#   --universal  build for both Apple Silicon and Intel (used for releases)
#   --install    also copy the app to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=false
INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=true ;;
        --install) INSTALL=true ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

APP="build/Mac Cleaner.app"

if [[ ! -f AppBundle/AppIcon.icns ]]; then
    swift scripts/make-icon.swift
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if $UNIVERSAL; then
    swift build -c release --triple arm64-apple-macosx14.0
    swift build -c release --triple x86_64-apple-macosx14.0
    lipo -create \
        .build/arm64-apple-macosx/release/MacCleaner \
        .build/x86_64-apple-macosx/release/MacCleaner \
        -output "$APP/Contents/MacOS/MacCleaner"
else
    swift build -c release
    cp "$(swift build -c release --show-bin-path)/MacCleaner" "$APP/Contents/MacOS/MacCleaner"
fi

cp AppBundle/Info.plist "$APP/Contents/Info.plist"
cp AppBundle/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so macOS will run it. (Not notarized: see the README for opening a downloaded copy.)
codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/MacCleaner"))"

if $INSTALL; then
    rm -rf "/Applications/Mac Cleaner.app"
    ditto "$APP" "/Applications/Mac Cleaner.app"
    echo "Installed to /Applications/Mac Cleaner.app"
fi
