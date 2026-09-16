# DesktopNamer

macOS Mission Control의 "데스크탑 N"에 내가 정한 이름을 붙이는 메뉴 막대 앱입니다.

- 메뉴 막대에 현재 데스크탑 이름이 항상 표시됩니다.
- 메뉴에서 데스크탑 목록을 보고 클릭해서 이동합니다.
- `이름 바꾸기…` 창에서 데스크탑마다 이름을 정합니다. 이름은 공간의 고유 ID에 저장되어 순서를 바꿔도 따라갑니다.
- (선택) Mission Control이 열리면 썸네일 아래 "데스크탑 N" 자리에 지정한 이름을 덮어 그립니다.

## 왜 "덮어 그리기"인가

macOS는 Mission Control의 데스크탑 이름을 바꾸는 공개 API를 제공하지 않습니다. 이 앱은 비공개 SkyLight API로 공간 목록과 현재 공간을 읽고, Mission Control이 열린 동안 Dock의 접근성 트리에서 썸네일 위치를 읽어 투명 패널에 이름표를 그립니다. 그래서:

- 비공개 API를 쓰므로 App Store 배포는 불가하고, macOS 대규모 업데이트 뒤 동작이 바뀔 수 있습니다.
- 오버레이 기능은 **손쉬운 사용(접근성) 권한**이 필요합니다.
- 메뉴 막대 표시와 이름 저장은 오버레이 없이도 동작합니다.

## 빌드 (macOS 13 이상, Xcode Command Line Tools 필요)

```bash
./scripts/build-app.sh          # build/DesktopNamer.app 생성
open build/DesktopNamer.app
```

디버그 빌드는 `./scripts/build-app.sh debug`.

## 사용

1. 앱을 실행하면 메뉴 막대 오른쪽에 격자 아이콘과 현재 데스크탑 이름이 보입니다.
2. 아이콘을 눌러 `이름 바꾸기…`를 선택하고 각 데스크탑의 이름을 입력합니다. 입력 즉시 저장됩니다.
3. `Mission Control에 이름 겹쳐 보이기`를 켜면 접근성 권한 요청이 뜹니다. 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 DesktopNamer를 허용하세요.
4. Mission Control(F3 또는 ⌃↑)을 열면 이름표가 나타납니다.

## 구조

| 파일 | 역할 |
| --- | --- |
| `SkyLight.swift` | 비공개 공간 API를 dlsym으로 로드 |
| `SpaceManager.swift` | 공간 목록/현재 공간 추적 |
| `SpaceSwitcher.swift` | ⌃숫자 단축키를 대신 눌러 데스크탑 전환 |
| `NameStore.swift` | UUID → 이름 저장 (UserDefaults) |
| `StatusBarController.swift` | 메뉴 막대 항목과 메뉴 |
| `RenameWindow.swift` | 이름 편집 창 (SwiftUI) |
| `DockAccessibility.swift` | Mission Control 중 Dock 접근성 트리에서 썸네일 위치 읽기 |
| `MissionControlOverlay.swift` | 이름표 오버레이 패널 |

## 알려진 제한

- 이름표는 원래 라벨을 "덮는" 것이므로 위치가 어긋나면 `MissionControlOverlay.swift`의 `labelBottomInset` 값을 조정하세요.
- 메뉴에서 데스크탑 전환은 macOS 단축키(⌃1~⌃9, ⌃0)를 대신 눌러 주는 방식입니다. 시스템 설정 > 키보드 > 키보드 단축키 > Mission Control에서 "데스크탑 N으로 전환"이 켜져 있어야 하고, 접근성 권한이 필요합니다. 11번째 이후 데스크탑은 메뉴에서 전환할 수 없습니다.
- 비공개 API로 공간을 직접 바꾸는 방식(`CGSManagedDisplaySetCurrentSpace`)은 Dock과 상태가 어긋나 창이 다른 데스크탑에 나타나는 문제가 있어 사용하지 않습니다.
- 전체 화면 앱 공간은 이름을 지정할 수 없습니다(Mission Control이 앱 이름을 표시).
