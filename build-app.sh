#!/usr/bin/env bash
set -eo pipefail

APP_NAME="MediaVault"
APP_BUNDLE="${APP_NAME}.app"
BUILD_OUT=".build/mediavault-binary"

SDK=$(xcrun --show-sdk-path)
SOURCES=$(find Sources/MediaVault -name "*.swift" | sort | tr '\n' ' ')

echo "Building ${APP_NAME}..."
mkdir -p .build
mkdir -p .build/module-cache

# Clear module cache if compiler and SDK versions don't match (happens after Xcode updates)
SWIFT_VER=$(swiftc --version 2>&1 | head -1)
CACHE_VER_FILE=".build/module-cache/.swift-version"
if [ -f "$CACHE_VER_FILE" ] && [ "$(cat "$CACHE_VER_FILE")" != "$SWIFT_VER" ]; then
    echo "Swift version changed, clearing module cache..."
    rm -rf .build/module-cache
    mkdir -p .build/module-cache
fi
echo "$SWIFT_VER" > "$CACHE_VER_FILE"

swiftc \
    -sdk "$SDK" \
    -target arm64-apple-macosx13.0 \
    -parse-as-library \
    -module-cache-path .build/module-cache \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation \
    -framework LocalAuthentication \
    -o "$BUILD_OUT" \
    $SOURCES

echo "Assembling ${APP_BUNDLE}..."
rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "$BUILD_OUT" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

cat > "${APP_BUNDLE}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>MediaVault</string>
    <key>CFBundleIdentifier</key>          <string>com.mediavault.app</string>
    <key>CFBundleName</key>                <string>MediaVault</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>1.0</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>LSMinimumSystemVersion</key>      <string>13.0</string>
    <key>NSPrincipalClass</key>            <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>NSFaceIDUsageDescription</key>    <string>Unlock private groups in MediaVault</string>
</dict>
</plist>
PLIST

echo "Signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Done: $(pwd)/${APP_BUNDLE}"
echo "Run:  open ${APP_BUNDLE}"
