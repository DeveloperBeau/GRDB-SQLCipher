#!/bin/bash
# Builds the binary distribution (iOS device, iOS simulator, macOS) from
# this package, with SQLCipher compiled in.
#
# Usage: Scripts/build-xcframework.sh [output-directory]
#
# The output zip contains three XCFrameworks that must be embedded together:
#
# - GRDB.xcframework: the GRDB module, with all SQLCipher and SQLite code
#   linked in.
# - SQLCipher.xcframework and GRDBSQLCipher.xcframework: header-only
#   companions (their libraries are empty stubs). GRDB's Swift interface
#   imports these two clang modules, so consumers need them resolvable at
#   compile time; the symbols themselves live in GRDB.framework.
#
# xcodebuild archives the GRDB-dynamic package product, but does not place
# the Swift module or the resource bundle inside the archived framework, and
# names the framework after the product rather than the module. This script
# assembles a proper GRDB.framework for each platform.
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
        (cd "$FRAMEWORK" && ln -s "Versions/Current/Modules" "Modules")
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

echo "=== Preparing companion headers"
# The SQLCipher module headers, with the codec-related macros pre-defined:
# consumers compile GRDB's Swift interface without this package's cSettings.
mkdir -p "$WORK/sqlcipher-hdrs/SQLCipher" "$WORK/shim-hdrs"
{
    printf '#ifndef SQLITE_HAS_CODEC\n#define SQLITE_HAS_CODEC 1\n#endif\n'
    printf '#ifndef SQLITE_ENABLE_FTS5\n#define SQLITE_ENABLE_FTS5 1\n#endif\n'
    printf '#ifndef SQLITE_ENABLE_SNAPSHOT\n#define SQLITE_ENABLE_SNAPSHOT 1\n#endif\n'
    cat "$REPO/Sources/SQLCipher/include/SQLCipher/sqlite3.h"
} > "$WORK/sqlcipher-hdrs/SQLCipher/sqlite3.h"
printf 'module SQLCipher {\n    header "SQLCipher/sqlite3.h"\n    export *\n}\n' \
    > "$WORK/sqlcipher-hdrs/module.modulemap"
cp "$REPO/Sources/GRDBSQLCipher/include/SQLCipher_config.h" "$WORK/shim-hdrs/"
printf 'module GRDBSQLCipher {\n    header "SQLCipher_config.h"\n    export *\n}\n' \
    > "$WORK/shim-hdrs/module.modulemap"

echo "=== Building stub libraries"
# xcodebuild -create-xcframework needs a binary per slice; these carry no
# symbols. One object per architecture, joined with lipo where needed.
stub_lib() { # <output.a> <sdk> <target...>
    local lib=$1 sdk=$2; shift 2
    local objs=()
    for target in "$@"; do
        echo "static const int stub = 0;" \
            | xcrun clang -x c - -c -target "$target" \
                -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
                -o "$lib-$target.o"
        objs+=("$lib-$target.o")
    done
    if [ ${#objs[@]} -gt 1 ]; then
        local thins=()
        for obj in "${objs[@]}"; do
            (cd "$(dirname "$obj")" && ar -crs "$obj.a" "$(basename "$obj")")
            thins+=("$obj.a")
        done
        lipo -create "${thins[@]}" -output "$lib"
    else
        ar -crs "$lib" "${objs[@]}"
    fi
}
mkdir -p "$WORK/stubs/ios" "$WORK/stubs/sim" "$WORK/stubs/macos"
stub_lib "$WORK/stubs/ios/stub.a" iphoneos arm64-apple-ios13.0
stub_lib "$WORK/stubs/sim/stub.a" iphonesimulator arm64-apple-ios13.0-simulator x86_64-apple-ios13.0-simulator
stub_lib "$WORK/stubs/macos/stub.a" macosx arm64-apple-macos10.15 x86_64-apple-macos10.15

echo "=== Creating XCFrameworks"
BUNDLE="$WORK/bundle"
mkdir -p "$BUNDLE"
xcodebuild -create-xcframework "${FRAMEWORK_ARGS[@]}" -output "$BUNDLE/GRDB.xcframework"
for module in SQLCipher GRDBSQLCipher; do
    case $module in
        SQLCipher) HDRS="$WORK/sqlcipher-hdrs" ;;
        GRDBSQLCipher) HDRS="$WORK/shim-hdrs" ;;
    esac
    xcodebuild -create-xcframework \
        -library "$WORK/stubs/ios/stub.a" -headers "$HDRS" \
        -library "$WORK/stubs/sim/stub.a" -headers "$HDRS" \
        -library "$WORK/stubs/macos/stub.a" -headers "$HDRS" \
        -output "$BUNDLE/$module.xcframework"
done

echo "=== Verifying the macOS slice"
cat > "$WORK/verify.swift" <<'EOF'
import GRDB
let dbQueue = try DatabaseQueue()
let version = try dbQueue.read { db in
    try String.fetchOne(db, sql: "PRAGMA cipher_version")
}
guard let version, !version.isEmpty else {
    fatalError("no cipher_version: the codec is missing from the framework")
}
print("cipher_version: \(version)")
EOF
MACOS_SLICE="$BUNDLE/GRDB.xcframework/macos-arm64_x86_64"
xcrun swiftc \
    -F "$MACOS_SLICE" \
    -I "$BUNDLE/SQLCipher.xcframework/macos-arm64_x86_64/Headers" \
    -I "$BUNDLE/GRDBSQLCipher.xcframework/macos-arm64_x86_64/Headers" \
    -framework GRDB \
    -o "$WORK/verify" "$WORK/verify.swift"
DYLD_FRAMEWORK_PATH="$MACOS_SLICE" "$WORK/verify"

rm -rf "$OUT/GRDB.xcframework.zip"
(cd "$BUNDLE" && zip -qry "$OUT/GRDB.xcframework.zip" .)
echo "=== Done: $OUT/GRDB.xcframework.zip"
