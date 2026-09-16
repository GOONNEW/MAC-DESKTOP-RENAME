#!/bin/bash
# 최신 코드를 내려받아 빌드만 한다 (앱 실행/종료는 하지 않음).
# 앱의 업데이트 창이 이 스크립트를 호출한다.
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

./scripts/build-app.sh
