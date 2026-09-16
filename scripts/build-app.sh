#!/bin/bash
# swift build 결과를 .app 번들로 감싼다. macOS에서 실행: ./scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DesktopNamer"
BUNDLE_ID="com.example.desktopnamer"
CONFIG="${1:-release}"
OUT_DIR="build"
APP="$OUT_DIR/$APP_NAME.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>데스크탑 이름</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 접근성 권한이 빌드마다 초기화되지 않도록 ad-hoc 서명
codesign --force --sign - "$APP"

echo "빌드 완료: $APP"
echo "실행: open \"$APP\""
