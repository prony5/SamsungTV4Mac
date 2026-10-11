#!/bin/bash
# Builds SamsungTV4Mac.app and a .dmg into .build/release.
#   UNIVERSAL=1 ./build-dmg.sh   — arm64 + x86_64
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="SamsungTV4Mac"
BUNDLE_ID="io.github.prony5.SamsungTV4Mac"
VERSION="$(tr -d '[:space:]' < VERSION)"
OUT_DIR=".build/release"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"
DMG_OUTPUT="$OUT_DIR/$APP_NAME-$VERSION.dmg"

echo "==> Building $APP_NAME $VERSION..."
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    # Build each architecture separately and merge with lipo (works without Xcode).
    for ARCH in arm64 x86_64; do
        swift build -c release --arch "$ARCH"
    done
    BINARY="$OUT_DIR/$APP_NAME-universal"
    lipo -create -output "$BINARY" \
        "$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME" \
        "$(swift build -c release --arch x86_64 --show-bin-path)/$APP_NAME"
else
    swift build -c release
    BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"
fi

echo "==> Creating .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/"
cp -R Resources/*.lproj "$APP_BUNDLE/Contents/Resources/"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>ru</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>SamsungTV4Mac finds TVs on your local network and streams videos to them.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Video</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
                <string>public.audiovisual-content</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Localized permission prompt.
mkdir -p "$APP_BUNDLE/Contents/Resources/ru.lproj"
cat > "$APP_BUNDLE/Contents/Resources/ru.lproj/InfoPlist.strings" <<'STRINGS'
"NSLocalNetworkUsageDescription" = "SamsungTV4Mac ищет телевизоры в локальной сети и передаёт на них видео.";
STRINGS

echo "==> Signing (ad-hoc)..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Creating DMG..."
STAGING="$(mktemp -d)"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG_OUTPUT"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_OUTPUT" >/dev/null
rm -rf "$STAGING"

echo "==> Done:"
echo "    $APP_BUNDLE"
echo "    $DMG_OUTPUT"
