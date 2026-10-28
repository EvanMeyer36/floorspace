#!/bin/bash
# Builds "Floorspace.app" into ./build.
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

APP="build/Floorspace.app"

if [[ ! -f AppBundle/AppIcon.icns ]]; then
    swift scripts/make-icon.swift
fi

# The shared Rust engine, linked into the app as a static library.
if $UNIVERSAL; then ./scripts/build-rust.sh --universal; else ./scripts/build-rust.sh; fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if $UNIVERSAL; then
    swift build -c release --triple arm64-apple-macosx14.0
    swift build -c release --triple x86_64-apple-macosx14.0
    lipo -create \
        .build/arm64-apple-macosx/release/Floorspace \
        .build/x86_64-apple-macosx/release/Floorspace \
        -output "$APP/Contents/MacOS/Floorspace"
else
    swift build -c release
    cp "$(swift build -c release --show-bin-path)/Floorspace" "$APP/Contents/MacOS/Floorspace"
fi

cp AppBundle/Info.plist "$APP/Contents/Info.plist"
cp AppBundle/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so macOS will run it. (Not notarized: see the README for opening a downloaded copy.)
codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Floorspace"))"

if $INSTALL; then
    rm -rf "/Applications/Floorspace.app"
    ditto "$APP" "/Applications/Floorspace.app"
    echo "Installed to /Applications/Floorspace.app"
fi
