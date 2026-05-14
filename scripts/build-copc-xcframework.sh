#!/bin/bash
# Build copc-lib + laz-perf as a multi-platform xcframework matching the
# pdalcpp.xcframework pattern. Output: Frameworks/copclib.xcframework
#
# Slices built by default:
#   - macOS arm64 + x86_64 (combined)
#   - iOS arm64 (device)
#   - iOS simulator arm64 + x86_64 (combined)
#
# Override with PLATFORMS env var, e.g.:
#   PLATFORMS="macos" ./scripts/build-copc-xcframework.sh   # macOS only (fastest)
#
# Requires: cmake, xcodebuild, libtool (xcrun finds these).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/Frameworks"
WORK_DIR="${WORK_DIR:-/tmp/copc-xcf-build}"
COPC_TAG="${COPC_TAG:-v2.6.3}"
LAZPERF_TAG="${LAZPERF_TAG:-master}"
PLATFORMS="${PLATFORMS:-macos ios ios-sim}"
MACOS_MIN="${MACOS_MIN:-13.0}"
IOS_MIN="${IOS_MIN:-17.0}"

# --- Fetch sources ---------------------------------------------------------
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if [ ! -d "copc-lib" ]; then
    git clone --depth 1 --branch "$COPC_TAG" https://github.com/RockRobotic/copc-lib.git
fi
if [ ! -d "copc-lib/libs/laz-perf" ]; then
    git clone --depth 1 --branch "$LAZPERF_TAG" https://github.com/hobuinc/laz-perf.git copc-lib/libs/laz-perf
fi

# --- Helpers ---------------------------------------------------------------
# build_slice <slice-name> <cmake-extra-flags...>
# Produces: $WORK_DIR/install-<slice>/lib/{libcopc-lib.a,liblazperf.a}
#           $WORK_DIR/install-<slice>/lib/libcopclib-combined.a
#           (headers identical across slices; we take macOS as canonical)
build_slice() {
    local slice="$1"; shift
    local build_dir="$WORK_DIR/build-$slice"
    local install_dir="$WORK_DIR/install-$slice"
    rm -rf "$build_dir" "$install_dir"
    mkdir -p "$build_dir"
    cd "$build_dir"

    cmake "$WORK_DIR/copc-lib" \
        -DBUILD_SHARED_LIBS=OFF \
        -DWITH_TESTS=OFF \
        -DWITH_PYTHON=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$install_dir" \
        "$@" >/dev/null

    cmake --build . --target install -j 2>&1 | tail -3

    # Combine copc-lib + lazperf into one static lib for xcframework.
    libtool -static -o "$install_dir/lib/libcopclib-combined.a" \
        "$install_dir/lib/libcopc-lib.a" \
        "$install_dir/lib/liblazperf.a"
    cd "$WORK_DIR"
}

# --- macOS (arm64 + x86_64) ------------------------------------------------
if [[ " $PLATFORMS " == *" macos "* ]]; then
    echo "==> Building macOS slice (arm64;x86_64)"
    build_slice "macos" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
        -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
fi

# --- iOS device (arm64) ----------------------------------------------------
if [[ " $PLATFORMS " == *" ios "* ]]; then
    echo "==> Building iOS device slice (arm64)"
    IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
    build_slice "ios" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$IOS_SDK" \
        -DCMAKE_OSX_ARCHITECTURES="arm64" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
        -DCMAKE_IOS_INSTALL_COMBINED=NO
fi

# --- iOS simulator (arm64 + x86_64) ----------------------------------------
if [[ " $PLATFORMS " == *" ios-sim "* ]]; then
    echo "==> Building iOS simulator slice (arm64;x86_64)"
    SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    build_slice "ios-sim" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$SIM_SDK" \
        -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN"
fi

# --- Assemble xcframework --------------------------------------------------
echo "==> Assembling xcframework"
HEADERS_DIR="$WORK_DIR/install-macos/include"
[ -d "$HEADERS_DIR" ] || HEADERS_DIR="$WORK_DIR/install-ios/include"
[ -d "$HEADERS_DIR" ] || HEADERS_DIR="$WORK_DIR/install-ios-sim/include"
if [ ! -d "$HEADERS_DIR" ]; then
    echo "ERROR: no install dir with headers" >&2; exit 1
fi

XCF_ARGS=()
[ -f "$WORK_DIR/install-macos/lib/libcopclib-combined.a" ] && \
    XCF_ARGS+=(-library "$WORK_DIR/install-macos/lib/libcopclib-combined.a" -headers "$HEADERS_DIR")
[ -f "$WORK_DIR/install-ios/lib/libcopclib-combined.a" ] && \
    XCF_ARGS+=(-library "$WORK_DIR/install-ios/lib/libcopclib-combined.a" -headers "$HEADERS_DIR")
[ -f "$WORK_DIR/install-ios-sim/lib/libcopclib-combined.a" ] && \
    XCF_ARGS+=(-library "$WORK_DIR/install-ios-sim/lib/libcopclib-combined.a" -headers "$HEADERS_DIR")

OUT_XCF="$OUT_DIR/copclib.xcframework"
rm -rf "$OUT_XCF"
mkdir -p "$OUT_DIR"
xcodebuild -create-xcframework "${XCF_ARGS[@]}" -output "$OUT_XCF"

echo "==> Built: $OUT_XCF"
ls "$OUT_XCF"

# Produce a release-ready zip + SHA256 checksum for URL-based
# binaryTarget consumption (matches the pdalcpp/gdal release pattern).
OUT_ZIP="$OUT_DIR/copclib.xcframework.zip"
rm -f "$OUT_ZIP"
( cd "$OUT_DIR" && zip -qr "copclib.xcframework.zip" "copclib.xcframework" )
CHECKSUM="$(swift package compute-checksum "$OUT_ZIP")"

echo "==> Release artifacts:"
echo "    zip:      $OUT_ZIP"
echo "    checksum: $CHECKSUM"
echo
echo "    To switch Package.swift to URL-based:"
echo "      .binaryTarget("
echo "          name: \"copclib\","
echo "          url: \"https://github.com/<owner>/SwiftPDAL/releases/download/<tag>/copclib.xcframework.zip\","
echo "          checksum: \"$CHECKSUM\""
echo "      )"
