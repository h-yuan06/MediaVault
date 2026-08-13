#!/usr/bin/env bash
set -eo pipefail

APP_NAME="MediaVault"
APP_BUNDLE="${APP_NAME}.app"
BUILD_NUMBER=${BUILD_NUMBER:-0}

# ---------------------------------------------------------------------------
# Compile — use xcodebuild locally (incremental via DerivedData) and swiftc
# on CI (no cache benefit, simpler invocation).
# ---------------------------------------------------------------------------
echo "Building ${APP_NAME} (build ${BUILD_NUMBER})..."

# ---------------------------------------------------------------------------
# Generate DownloadFinishedKeywords.swift from the markdown keyword list.
# This replaces the SPM build-tool plugin, which swiftc/xcodebuild skip.
# ---------------------------------------------------------------------------
KEYWORDS_MD="Sources/MediaVault/Resources/download-finished-keywords.md"
KEYWORDS_SWIFT="Sources/MediaVault/Generated/DownloadFinishedKeywords.swift"
mkdir -p "$(dirname "$KEYWORDS_SWIFT")"

{
  echo "// Auto-generated from download-finished-keywords.md — do not edit."
  echo "enum DownloadFinishedKeywords {"
  echo "    static let all: [String] = ["
  grep -v '^\s*#' "$KEYWORDS_MD" | grep -v '^\s*$' | while IFS= read -r line; do
    escaped="${line//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    echo "        \"$escaped\","
  done
  echo "    ]"
  echo "}"
} > "$KEYWORDS_SWIFT"

if [ "${CI}" = "true" ]; then
    SDK=$(xcrun --show-sdk-path)
    SOURCES=$(find Sources/MediaVault -name "*.swift" | sort | tr '\n' ' ')
    mkdir -p .build
    eval swiftc \
        -sdk "$SDK" \
        -target arm64-apple-macosx14.0 \
        -parse-as-library \
        -framework SwiftUI \
        -framework AppKit \
        -framework Foundation \
        -framework LocalAuthentication \
        -o .build/mediavault-binary \
        $SOURCES
    BINARY=".build/mediavault-binary"
else
    xcodebuild \
        -scheme MediaVault \
        -configuration Debug \
        -destination "platform=macOS,arch=arm64" \
        -derivedDataPath .build/xcode-derived \
        build \
        2>&1 | grep -E "^(error:|warning:|Build succeeded|FAILED|CompileSwift)" || true
    BINARY=$(find .build/xcode-derived/Build/Products -name "$APP_NAME" -type f | head -1)
    if [ -z "$BINARY" ]; then
        echo "ERROR: compiled binary not found — did the build succeed?"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Assemble the .app bundle
# ---------------------------------------------------------------------------
echo "Assembling ${APP_BUNDLE}..."
rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "$BINARY" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Copy bundled resources (player.html, etc.)
if [ -d "Sources/MediaVault/Resources" ]; then
    cp -r Sources/MediaVault/Resources/. "${APP_BUNDLE}/Contents/Resources/"
fi

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
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <key>NSPrincipalClass</key>            <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>NSFaceIDUsageDescription</key>    <string>Unlock private groups in MediaVault</string>
    <key>NSWindowSupportsFullScreen</key>  <true/>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "${APP_BUNDLE}/Contents/Info.plist"

echo "Signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Done: $(pwd)/${APP_BUNDLE}"
echo "Run:  open ${APP_BUNDLE}"
