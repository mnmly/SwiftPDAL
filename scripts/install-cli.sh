#!/usr/bin/env bash
#
# Release-build the PDAL2COPC CLI and install it as a relocatable,
# self-contained tool into a Homebrew-style prefix:
#
#   <prefix>/bin/PDAL2COPC                  the executable + its resource bundle
#   <prefix>/bin/SwiftPDAL_SwiftPDAL.bundle proj.db etc. (Bundle.module)
#   <prefix>/lib/{gdal,pdalcpp,E57Format}.framework
#
# The binary already carries an `@executable_path/../lib` rpath, so the
# frameworks resolve from <prefix>/lib with no patching. We additionally
# strip the absolute DerivedData rpath baked in at build time so the
# install does not depend on the build tree surviving.
#
#   scripts/install-cli.sh [PREFIX]      # default PREFIX=/usr/local
#
# Note: `swift build`/`swift run` cannot build this package (the C++
# SWIFT_SHARED_REFERENCE reader type); xcodebuild is the supported path.
set -euo pipefail

PREFIX="${1:-/usr/local}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$REPO/.build/xcode-release"
PROD="$DERIVED/Build/Products/Release"
FRAMEWORKS=(gdal pdalcpp E57Format)

echo "==> Building PDAL2COPC (Release)…"
xcodebuild -scheme PDAL2COPC -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" build >/dev/null

bin="$PROD/PDAL2COPC"
[ -x "$bin" ] || { echo "build did not produce $bin" >&2; exit 1; }

echo "==> Installing into $PREFIX …"
install_d() { [ -d "$1" ] || mkdir -p "$1"; }
install_d "$PREFIX/bin"
install_d "$PREFIX/lib"

# Stage to a temp dir so we can rewrite rpaths before placing under PREFIX.
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp "$bin" "$stage/PDAL2COPC"

# Drop any absolute DerivedData rpath; keep @executable_path/../lib.
while read -r rp; do
    case "$rp" in
        *DerivedData*|*"$DERIVED"*)
            install_name_tool -delete_rpath "$rp" "$stage/PDAL2COPC" 2>/dev/null || true
            ;;
    esac
done < <(otool -l "$stage/PDAL2COPC" | awk '/LC_RPATH/{getline;getline;print $2}')

cp "$stage/PDAL2COPC" "$PREFIX/bin/PDAL2COPC"
rm -rf "$PREFIX/bin/SwiftPDAL_SwiftPDAL.bundle"
cp -R "$PROD/SwiftPDAL_SwiftPDAL.bundle" "$PREFIX/bin/"
for fw in "${FRAMEWORKS[@]}"; do
    rm -rf "$PREFIX/lib/$fw.framework"
    cp -R "$PROD/$fw.framework" "$PREFIX/lib/"
done

echo "==> Installed: $PREFIX/bin/PDAL2COPC"
echo "    Frameworks: $PREFIX/lib/{$(IFS=,; echo "${FRAMEWORKS[*]}")}.framework"
"$PREFIX/bin/PDAL2COPC" 2>&1 | head -1 || true
