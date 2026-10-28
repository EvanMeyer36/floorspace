#!/bin/bash
# Builds the Rust engine (floorspace-ffi) as a static library into macos/rust/ for the Swift app.
#   --universal  Apple Silicon + Intel (for releases); otherwise this Mac's architecture only
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="rust"
mkdir -p "$OUT"
export MACOSX_DEPLOYMENT_TARGET=14.0

if [[ "${1:-}" == "--universal" ]]; then
    for target in aarch64-apple-darwin x86_64-apple-darwin; do
        rustup target add "$target" >/dev/null 2>&1 || true
        cargo build --release -p floorspace-ffi --target "$target" --manifest-path ../Cargo.toml
    done
    lipo -create \
        ../target/aarch64-apple-darwin/release/libfloorspace_ffi.a \
        ../target/x86_64-apple-darwin/release/libfloorspace_ffi.a \
        -output "$OUT/libfloorspace_ffi.a"
else
    cargo build --release -p floorspace-ffi --manifest-path ../Cargo.toml
    cp ../target/release/libfloorspace_ffi.a "$OUT/libfloorspace_ffi.a"
fi
echo "Engine library: $OUT/libfloorspace_ffi.a ($(lipo -archs "$OUT/libfloorspace_ffi.a"))"
