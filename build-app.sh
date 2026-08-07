#!/usr/bin/env bash
set -eo pipefail

APP_NAME="MediaVault"
APP_BUNDLE="${APP_NAME}.app"
BUILD_NUMBER=${BUILD_NUMBER:-0}

# ---------------------------------------------------------------------------
# Compile — use xcodebuild so incremental builds share Xcode's DerivedData
# cache. After the first build this is as fast as Cmd+B in Xcode.
# ---------------------------------------------------------------------------
echo "Building ${APP_NAME} (build ${BUILD_NUMBER})..."
xcodebuild \
    -scheme MediaVault \
    -configuration Debug \
    -derivedDataPath .build/xcode-derived \
    build \
    2>&1 | grep -E "^(error:|warning:|Build succeeded|FAILED|CompileSwift)" || true

# Locate the compiled binary inside DerivedData
BINARY=$(find .build/xcode-derived/Build/Products -name "$APP_NAME" -type f | head -1)
if [ -z "$BINARY" ]; then
    echo "ERROR: compiled binary not found — did the build succeed?"
    exit 1
fi

# ---------------------------------------------------------------------------
# Assemble the .app bundle
# ---------------------------------------------------------------------------
echo "Assembling ${APP_BUNDLE}..."
rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "$BINARY" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

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
    <key>CFBundleVersion</key>             <string>0</string>
    <key>LSMinimumSystemVersion</key>      <string>13.0</string>
    <key>NSPrincipalClass</key>            <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>NSFaceIDUsageDescription</key>    <string>Unlock private groups in MediaVault</string>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "${APP_BUNDLE}/Contents/Info.plist"

echo "Signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Done: $(pwd)/${APP_BUNDLE}"
echo "Run:  open ${APP_BUNDLE}"
