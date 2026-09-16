#!/bin/bash
# GitHub에서 최신 코드를 내려받아 이 폴더를 갱신한 뒤 빌드하고 실행한다.
# 사용: ./scripts/update.sh
set -euo pipefail
cd "$(dirname "$0")/.."

BRANCH="claude/determined-heisenberg-04924x"
URL="https://github.com/GOONNEW/MAC-DESKTOP-RENAME/archive/refs/heads/$BRANCH.zip"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "최신 코드 내려받는 중..."
curl -fsSL -o "$TMP/src.zip" "$URL"
unzip -qo "$TMP/src.zip" -d "$TMP/src"
SRC="$(find "$TMP/src" -mindepth 1 -maxdepth 1 -type d | head -1)"

mkdir -p Sources scripts
cp -R "$SRC/Sources/." Sources/
cp -R "$SRC/scripts/." scripts/
cp "$SRC/Package.swift" "$SRC/README.md" .
chmod +x scripts/*.sh

# 실행 중인 이전 버전은 종료
pkill -x DesktopNamer 2>/dev/null || true

./scripts/build-app.sh
# 터미널에서 open으로 실행하면 접근성 권한이 터미널 기준으로 판정될 수 있으므로,
# Finder 창을 열어 주고 사용자가 더블클릭으로 실행하게 한다.
open build
echo
echo "완료. Finder 창에서 DesktopNamer.app을 더블클릭해 실행하세요."
echo "(터미널에서 open으로 실행하면 접근성 권한이 인식되지 않을 수 있습니다.)"
