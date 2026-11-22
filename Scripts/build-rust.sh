#!/bin/sh
# Builds the cgm-sibionics Rust driver:
#
#   Rust/CgmSibionicsFFI.xcframework                 static library for iOS, iOS simulator, macOS
#   SibionicsKit/Rust/Generated/cgm_sibionics_ffi.swift   UniFFI Swift bindings (compiled into SibionicsKit)
#
# Usage: Scripts/build-rust.sh [path/to/cgm-sibionics]   (default "../../../Unified OS-AID/cgm-sibionics")
# Needs rustup targets aarch64-apple-ios, aarch64-apple-ios-sim, x86_64-apple-ios, aarch64-apple-darwin.
set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"
crate="$(cd "${1:-$here/../../../Unified OS-AID/cgm-sibionics}" && pwd)"
out="$here/SibionicsKit/Rust"
framework="$here/Rust/CgmSibionicsFFI.xcframework"
lib=libcgm_sibionics_ffi.a
profile=release

export PATH="$HOME/.cargo/bin:$PATH"
export CARGO_NET_GIT_FETCH_WITH_CLI=true
# xcodebuild needs a full Xcode; use it without changing xcode-select.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "$crate"
for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin; do
    # Only the static library: a cdylib for iOS would need the full SDK link.
    cargo rustc -p cgm-sibionics-ffi --lib --release --target "$target" --crate-type staticlib
done

# Bindings come from the host build of the same sources.
cargo build -p cgm-sibionics-ffi --release
gen="$(mktemp -d)"
cargo run -q -p cgm-sibionics-ffi --release --bin uniffi-bindgen -- \
    generate --library "target/$profile/libcgm_sibionics_ffi.dylib" --language swift --out-dir "$gen"

headers="$gen/headers"
mkdir -p "$headers"
cp "$gen/cgm_sibionics_ffiFFI.h" "$headers/"
# An XCFramework's headers need the module map under this exact name.
cp "$gen/cgm_sibionics_ffiFFI.modulemap" "$headers/module.modulemap"

# One simulator slice for both architectures (Intel and Apple-silicon simulators).
simulator="$gen/simulator"
mkdir -p "$simulator"
lipo -create \
    "target/aarch64-apple-ios-sim/$profile/$lib" \
    "target/x86_64-apple-ios/$profile/$lib" \
    -output "$simulator/$lib"

rm -rf "$framework"
mkdir -p "$out/Generated" "$(dirname "$framework")"
xcodebuild -create-xcframework \
    -library "target/aarch64-apple-ios/$profile/$lib" -headers "$headers" \
    -library "$simulator/$lib" -headers "$headers" \
    -library "target/aarch64-apple-darwin/$profile/$lib" -headers "$headers" \
    -output "$framework"
cp "$gen/cgm_sibionics_ffi.swift" "$out/Generated/cgm_sibionics_ffi.swift"
rm -rf "$gen"
echo "built $(git -C "$crate" rev-parse --short HEAD) into $out"
