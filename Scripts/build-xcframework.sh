#!/bin/bash
# Builds GRDB.xcframework (iOS device, iOS simulator, macOS) from this
# package, with SQLCipher compiled in.
#
# Usage: Scripts/build-xcframework.sh [output-directory]
#
# xcodebuild archives the GRDB-dynamic package product, but does not place
# the Swift module or the resource bundle inside the archived framework, and
# names the framework after the product rather than the module. This script
# assembles a proper GRDB.framework for each platform, then bundles the
# three into an XCFramework.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-"$REPO/dist"}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Export a clean copy of the package. The upstream Xcode projects must be
# absent: xcodebuild only treats the directory as a package when no
# .xcodeproj is present.
mkdir "$WORK/src"
git -C "$REPO" archive HEAD | tar -x -C "$WORK/src"
rm -rf "$WORK/src"/*.xcodeproj "$WORK/src"/*.xcworkspace

FRAMEWORK_ARGS=()
while IFS='|' read -r DESTINATION PRODUCTS_DIR; do
    [ -n "$DESTINATION" ] || continue
    NAME=$(echo "$PRODUCTS_DIR" | tr -d '-')

    echo "=== Archiving for $DESTINATION"
    (cd "$WORK/src" && xcodebuild archive \
        -scheme GRDB-dynamic \
        -destination "$DESTINATION" \
        -archivePath "$WORK/$NAME.xcarchive" \
        -derivedDataPath "$WORK/$NAME-dd" \
        SKIP_INSTALL=NO \
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
        -quiet)

    ARCHIVE_FRAMEWORK="$WORK/$NAME.xcarchive/Products/usr/local/lib/GRDB-dynamic.framework"
    PRODUCTS="$WORK/$NAME-dd/Build/Intermediates.noindex/ArchiveIntermediates/GRDB-dynamic/BuildProductsPath/$PRODUCTS_DIR"
    FRAMEWORK="$WORK/$NAME/GRDB.framework"

    echo "=== Assembling GRDB.framework for $DESTINATION"
    mkdir -p "$WORK/$NAME"
    cp -R "$ARCHIVE_FRAMEWORK" "$FRAMEWORK"
    if [ -d "$FRAMEWORK/Versions" ]; then
        # macOS: versioned bundle layout
        ROOT="$FRAMEWORK/Versions/A"
        RESOURCES="$ROOT/Resources"
        (cd "$FRAMEWORK" && rm "GRDB-dynamic" && ln -s "Versions/Current/GRDB" "GRDB")
        INSTALL_NAME="@rpath/GRDB.framework/Versions/A/GRDB"
    else
        ROOT="$FRAMEWORK"
        RESOURCES="$ROOT"
        INSTALL_NAME="@rpath/GRDB.framework/GRDB"
    fi
    mv "$ROOT/GRDB-dynamic" "$ROOT/GRDB"
    install_name_tool -id "$INSTALL_NAME" "$ROOT/GRDB"
    plutil -replace CFBundleExecutable -string "GRDB" "$RESOURCES/Info.plist"
    plutil -replace CFBundleIdentifier -string "org.grdb.GRDB" "$RESOURCES/Info.plist"
    plutil -replace CFBundleName -string "GRDB" "$RESOURCES/Info.plist"
    mkdir "$ROOT/Modules"
    cp -R "$PRODUCTS/GRDB.swiftmodule" "$ROOT/Modules/"
    # Package interfaces are only meaningful inside the package.
    rm -f "$ROOT/Modules/GRDB.swiftmodule"/*.package.swiftinterface
    # The resource bundle carries the privacy manifest.
    cp -R "$PRODUCTS/GRDB_GRDB.bundle" "$RESOURCES/"

    FRAMEWORK_ARGS+=(-framework "$FRAMEWORK")
done <<'SLICES'
generic/platform=iOS|Release-iphoneos
generic/platform=iOS Simulator|Release-iphonesimulator
generic/platform=macOS|Release
SLICES

echo "=== Creating XCFramework"
rm -rf "$OUT/GRDB.xcframework" "$OUT/GRDB.xcframework.zip"
xcodebuild -create-xcframework "${FRAMEWORK_ARGS[@]}" -output "$OUT/GRDB.xcframework"
(cd "$OUT" && zip -qry GRDB.xcframework.zip GRDB.xcframework)
echo "=== Done: $OUT/GRDB.xcframework.zip"
