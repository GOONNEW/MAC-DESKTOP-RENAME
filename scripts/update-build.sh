#!/bin/bash
# 최신 코드를 내려받아 빌드만 한다 (앱 실행/종료는 하지 않음).
# 앱의 업데이트 창이 이 스크립트를 호출한다.
set -euo pipefail

# 이 스크립트는 실행 중에 자기 자신을 갱신한다. bash는 스크립트를 조금씩 읽어 가며
# 실행하므로, 읽는 도중에 파일 내용이 바뀌면 엉뚱한 위치부터 이어 읽어 주석 조각을
# 명령으로 실행해 버린다. (실제로 "더에서도: command not found" 오류가 났다)
#
# 두 가지로 막는다.
# 1. 전체를 main 함수로 감싼다. bash는 함수 정의를 끝까지 읽어 해석한 뒤에야
#    실행하므로, 마지막 줄에서 main을 부를 때는 이미 파일을 다 읽은 상태다.
# 2. 복사를 rsync로 한다. rsync는 임시 파일에 쓴 뒤 이름만 바꿔치기하므로
#    실행 중인 파일 자체(inode)를 건드리지 않는다. cp는 제자리에서 덮어써서 위험하다.
main() {
  cd "$(dirname "$0")/.."

  local branch="claude/determined-heisenberg-04924x"
  local url="https://github.com/GOONNEW/MAC-DESKTOP-RENAME/archive/refs/heads/$branch.zip"

  if ! command -v rsync >/dev/null 2>&1; then
    echo "rsync를 찾을 수 없습니다. 업데이트를 진행할 수 없습니다." >&2
    exit 1
  fi

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  echo "최신 코드 내려받는 중..."
  curl -fsSL -o "$tmp/src.zip" "$url"
  unzip -qo "$tmp/src.zip" -d "$tmp/src"

  local src
  src="$(find "$tmp/src" -mindepth 1 -maxdepth 1 -type d | head -1)"
  if [ -z "$src" ] || [ ! -d "$src/Sources" ]; then
    echo "내려받은 압축 파일에서 소스를 찾지 못했습니다." >&2
    exit 1
  fi

  mkdir -p Sources scripts
  # --delete로 맞춰야 위쪽에서 삭제한 파일이 내 폴더에서도 사라진다.
  # 덮어쓰기만 하면 지워진 파일이 남아 계속 함께 컴파일되고 결국 빌드가 깨진다.
  echo "소스 갱신 중..."
  rsync -a --delete "$src/Sources/" Sources/
  # scripts는 지금 실행 중인 파일이 들어 있어 --delete를 쓰지 않는다
  rsync -a "$src/scripts/" scripts/
  rsync -a "$src/Package.swift" "$src/README.md" .
  chmod +x scripts/*.sh

  ./scripts/build-app.sh
}

main "$@"
