#!/bin/bash
#
# Builds LineLight.app from source. No Xcode project, no dependencies —
# just the Swift compiler that ships with the Xcode Command Line Tools.
#
#   ./build.sh            build into ./build/LineLight.app
#   ./build.sh --install  also copy to ~/Applications and launch it
#
set -euo pipefail

APP_NAME="LineLight"
BUNDLE_ID="com.mok.linelight"
VERSION="1.0.0"

cd "$(dirname "$0")"
ROOT="$(pwd)"

# If xcode-select points at Xcode.app and its licence has not been accepted,
# every Command Line Tools shim (swiftc, git, clang) refuses to run. The
# standalone Command Line Tools have no licence gate, so prefer them.
if [[ -d /Library/Developer/CommandLineTools ]] && ! xcodebuild -version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  echo "==> Using Command Line Tools toolchain ($DEVELOPER_DIR)"
fi
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found."
  echo "Installing the Xcode Command Line Tools (a system dialog will appear)…"
  xcode-select --install || true
  echo
  echo "Finish that install, then run this script again."
  exit 1
fi

echo "==> Cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling"
swiftc -O \
  -target "$(uname -m)-apple-macos12.0" \
  -framework Cocoa \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  Sources/*.swift

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>           <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key>           <string>APPL</string>
  <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
  <key>CFBundleVersion</key>               <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>        <string>12.0</string>
  <key>LSUIElement</key>                   <true/>
  <key>CFBundleIconFile</key>              <string>AppIcon</string>
  <key>NSHighResolutionCapable</key>       <true/>
  <key>NSHumanReadableCopyright</key>      <string>© 2026 Mok Yii Chek · Built with Claude (Anthropic) · MIT</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ -f Icon.png ]]; then
  echo "==> Building icon"
  ICONSET="$BUILD/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  sips -z 16 16     Icon.png --out "$ICONSET/icon_16x16.png"      >/dev/null
  sips -z 32 32     Icon.png --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
  sips -z 32 32     Icon.png --out "$ICONSET/icon_32x32.png"      >/dev/null
  sips -z 64 64     Icon.png --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
  sips -z 128 128   Icon.png --out "$ICONSET/icon_128x128.png"    >/dev/null
  sips -z 256 256   Icon.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256   Icon.png --out "$ICONSET/icon_256x256.png"    >/dev/null
  sips -z 512 512   Icon.png --out "$ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512   Icon.png --out "$ICONSET/icon_512x512.png"    >/dev/null
  cp Icon.png "$ICONSET/icon_512x512@2x.png"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (skipped)"

echo "==> Built: $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  echo "==> Installing to $DEST"
  echo "==> Stopping any running copy"
  pkill -x "$APP_NAME" 2>/dev/null || true
  pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  sleep 2
  if pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    pkill -9 -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    sleep 1
  fi
  rm -rf "$DEST/$APP_NAME.app"
  cp -R "$APP" "$DEST/"
  xattr -dr com.apple.quarantine "$DEST/$APP_NAME.app" 2>/dev/null || true
  echo "==> Launching"
  open -n "$DEST/$APP_NAME.app"
  sleep 3
  echo "==> Running: $(pgrep -fl "$APP_NAME" | tr '\n' ' ')"
  # Leave no second copy lying around for Spotlight to index.
  rm -rf "$BUILD"
  echo
  echo "$APP_NAME is now in your menu bar (top right)."
fi
