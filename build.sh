#!/bin/bash
# Builds DropS3.app (release) into ./dist
#   VERSION=1.2.0 ./build.sh     sets the app version (default 1.0)
#   UNIVERSAL=1   ./build.sh     builds for Apple Silicon and Intel
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP="dist/DropS3.app"

# The classic SwiftPM build system works with just the Command Line Tools (no Xcode needed).
FLAGS=(-c release)
if swift build --help 2>/dev/null | grep -q -- '--build-system'; then FLAGS+=(--build-system native); fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "${UNIVERSAL:-0}" = "1" ]; then
    BINARIES=()
    for ARCH in arm64 x86_64; do
        swift build "${FLAGS[@]}" --triple "$ARCH-apple-macosx14.0"
        BINARIES+=("$(swift build "${FLAGS[@]}" --triple "$ARCH-apple-macosx14.0" --show-bin-path)/DropS3")
    done
    lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/DropS3"
else
    swift build "${FLAGS[@]}"
    cp "$(swift build "${FLAGS[@]}" --show-bin-path)/DropS3" "$APP/Contents/MacOS/DropS3"
fi

cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DropS3</string>
    <key>CFBundleDisplayName</key><string>DropS3</string>
    <key>CFBundleIdentifier</key><string>com.local.drops3</string>
    <key>CFBundleExecutable</key><string>DropS3</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>es</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>DropS3 connects to your S3 server on the local network to store your backups.</string>
    <!-- Garage is usually reached over plain http on a local network -->
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "OK → $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/DropS3"))"
