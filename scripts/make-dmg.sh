#!/bin/bash
# 설치용 DMG를 만든다. 사용: ./scripts/make-dmg.sh [버전]
# 결과: dist/DesktopNamer-<버전>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DesktopNamer"
VERSION="${1:-0.1.0}"
APP="build/$APP_NAME.app"
DIST="dist"
DMG="$DIST/$APP_NAME-$VERSION.dmg"

# 최신 상태로 빌드
./scripts/build-app.sh

[ -d "$APP" ] || { echo "앱을 찾지 못했습니다: $APP" >&2; exit 1; }

mkdir -p "$DIST"
rm -f "$DMG"

# DMG에 넣을 내용을 모을 폴더 (프로젝트 안에 만들어 경로 문제를 피한다)
STAGE="$DIST/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/READ-ME.txt" <<'GUIDE'
DesktopNamer 설치 방법

1. DesktopNamer 아이콘을 옆의 Applications 폴더로 끌어다 놓으세요.
2. 응용 프로그램 폴더에서 DesktopNamer를 실행합니다.
   "확인되지 않은 개발자" 경고가 뜨면, 앱 아이콘을 control 키를 누른 채
   클릭하고 "열기"를 선택하세요.
3. 메뉴 막대에 격자 아이콘이 생깁니다. 아이콘을 눌러
   "표시 설정 > 모든 데스크탑에 이름 준비"를 실행하세요.

권한 안내
- 손쉬운 사용 권한이 필요합니다. 처음 실행 시 안내가 뜨면 허용해 주세요.
  시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용
- 권한이 안 먹으면 메뉴의 "고급 > 접근성 권한 초기화 후 다시 요청"을 누르세요.

사용법
- 세 손가락으로 위로 쓸거나 Control+위쪽 화살표 또는 F3으로 Mission Control을
  열면 각 데스크탑 썸네일에 지정한 이름이 보입니다.
- 이름은 메뉴 막대 아이콘 > 이름 바꾸기 에서 정합니다.
GUIDE

# 압축된 읽기 전용 DMG 생성
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG"

echo
echo "설치 파일 생성 완료: $DMG"
du -h "$DMG" | cut -f1 | sed 's/^/크기: /'
