#!/bin/bash
# swift build 결과를 .app 번들로 감싼다. macOS에서 실행: ./scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DesktopNamer"
BUNDLE_ID="com.example.desktopnamer"
CONFIG="${1:-release}"
OUT_DIR="build"
APP="$OUT_DIR/$APP_NAME.app"

# 예전 버전에서 남았을 수 있는 소스 정리.
# 업데이트가 파일을 덮어쓰기만 하던 시절에 지워진 파일이 남아 함께 컴파일되면 빌드가 깨진다.
# (update-build.sh는 이제 rsync --delete로 맞추므로, 이 목록은 더 늘어나지 않는다)
for stale in MissionControlOverlay.swift ScreenText.swift; do
  if [ -f "Sources/DesktopNamer/$stale" ]; then
    rm -f "Sources/DesktopNamer/$stale"
    echo "예전 파일 정리: $stale"
  fi
done

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
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 자체 서명서(scripts/setup-signing.sh로 생성)가 있으면 그것으로 서명해 빌드 후에도 접근성 권한이 유지되게 한다.
# 없으면 ad-hoc 서명 (이 경우 다시 빌드할 때마다 손쉬운 사용 권한을 다시 등록해야 한다).
IDENTITY="DesktopNamer Local"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "서명: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "서명: ad-hoc (권한 유지를 원하면 ./scripts/setup-signing.sh 를 한 번 실행)"
fi

echo "빌드 완료: $APP"
echo "실행: Finder에서 $APP 을 더블클릭 (터미널의 open 명령으로 실행하면 접근성 권한이 인식되지 않을 수 있음)"
