# DesktopNamer

macOS Mission Control의 "데스크탑 N"에 내가 정한 이름을 붙이는 메뉴 막대 앱입니다.

- 메뉴 막대에 현재 데스크탑 이름이 항상 표시됩니다.
- 메뉴에서 데스크탑 목록을 보고 클릭해서 이동합니다. 각 데스크탑에 어떤 앱의 창이 열려 있는지 아이콘과 이름으로 함께 보여줍니다.
- Mission Control을 열면 각 데스크탑 썸네일 안에 지정한 이름이 보입니다. 평소 화면에서는 보이지 않습니다.
- 메뉴의 `이름 바꾸기` 하위 메뉴에서 데스크탑을 골라 바로 이름을 입력하거나, ⌥ 키를 누른 채 데스크탑 항목을 클릭해도 됩니다. `모두 편집…`은 전체 목록 창을 엽니다. 이름은 공간의 고유 ID에 저장되어 순서를 바꿔도 따라갑니다.
- (선택) Mission Control이 열리면 썸네일 아래 "데스크탑 N" 자리에 지정한 이름을 덮어 그립니다.

## 어떻게 동작하나

macOS는 Mission Control의 "데스크탑 N" 글자를 바꾸는 공개 API를 제공하지 않고, 최신 macOS에서는 Mission Control이 열려도 앱이 관찰할 수 있는 상태가 전혀 변하지 않습니다. 그래서 기본 방식은 **이름 배지**입니다.

데스크탑마다 그 데스크탑에만 속하는 작은 창(배지)을 하나 두고, 평소에는 완전히 투명하게 해 둡니다. Mission Control을 여는 동작(트랙패드 세 손가락 이상, ⌃↑, Mission Control 키)이 감지되면 배지를 보이게 바꿉니다. Mission Control 썸네일은 각 데스크탑을 실시간으로 축소해 보여주므로 배지가 썸네일 안에 이름으로 나타나고, 닫히는 신호(클릭, 키 입력, 데스크탑/앱 전환)가 오면 다시 투명해집니다.

- 아래쪽의 "데스크탑 N" 글자 자체는 그대로 남습니다. 그것을 바꿀 방법은 없습니다.
- Dock 아이콘이나 화면 모서리로 Mission Control을 열면 감지되지 않아 배지가 보이지 않습니다.
- 배지 창은 그 데스크탑이 활성일 때만 만들 수 있어, 방문한 데스크탑부터 생깁니다. 메뉴의 `모든 데스크탑에 이름 준비`로 한 번에 만들 수 있습니다.
- 비공개 SkyLight API로 공간 목록과 현재 공간을 읽으므로 App Store 배포는 불가하고, macOS 대규모 업데이트 뒤 동작이 바뀔 수 있습니다.
- 배지 방식은 **손쉬운 사용 권한**만 필요합니다. 화면 기록 권한은 아래 실험 기능에만 씁니다.
- macOS 14 이상이 필요합니다.

### 실험 기능: 화면을 읽어 라벨 덮어쓰기

메뉴의 `실험: 화면을 읽어 라벨 덮어쓰기`를 켜면, 화면 위쪽을 ScreenCaptureKit 스트림으로 받아 Vision으로 "데스크탑 N" 글자를 찾아 그 자리에 이름표를 덮습니다. 원래 글자를 실제로 가릴 수 있지만 **화면 기록 권한**이 필요하고, 메뉴 막대에 화면 기록 표시가 뜨며, 썸네일이 움직이는 동안에는 따라가지 못합니다.

## 빌드 (macOS 14 이상, Xcode Command Line Tools 필요)

```bash
./scripts/build-app.sh          # build/DesktopNamer.app 생성
open build                      # Finder에서 build 폴더를 연 뒤 DesktopNamer.app을 더블클릭
```

앱은 Finder에서 더블클릭으로 실행하세요. 터미널에서 `open build/DesktopNamer.app`으로 실행하면 macOS가 접근성 권한을 터미널 기준으로 판정해 Mission Control 오버레이가 동작하지 않을 수 있습니다.

디버그 빌드는 `./scripts/build-app.sh debug`.

이미 폴더가 있다면 메뉴 막대 아이콘 → `최신 버전으로 업데이트…`를 누르면 진행 창이 뜨고 끝나면 새 버전으로 다시 시작합니다. 터미널에서 직접 하려면:

```bash
./scripts/update.sh
```

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
| `WindowInspector.swift` | 열린 창을 훑어 데스크탑별 앱 목록/아이콘 정리 |
| `NameStore.swift` | UUID → 이름 저장 (UserDefaults) |
| `StatusBarController.swift` | 메뉴 막대 항목과 메뉴 |
| `RenameWindow.swift` | 이름 편집 창 (SwiftUI) |
| `DockAccessibility.swift` | 접근성 권한 관리, Mission Control 열림 감지, 진단 |
| `ScreenText.swift` | 화면 위쪽 스트림 캡처와 "데스크탑 N" 글자 인식 |
| `MissionControlTrigger.swift` | Mission Control을 여는 키 감지 (이벤트 탭) |
| `TrackpadMonitor.swift` | 트랙패드에 닿은 손가락 개수 읽기 |
| `MissionControlSignals.swift` | 열림/닫힘 추정 신호를 모아 전달 |
| `BadgeManager.swift` | 데스크탑별 이름 배지 창 (기본 방식) |
| `MissionControlOverlay.swift` | 이름표 오버레이 패널 |

## 다시 빌드한 뒤 접근성 권한이 안 먹을 때

한 번만 아래를 실행해 자체 서명서를 만들어 두면 이후 빌드에서도 권한이 유지됩니다. 암호 입력 창이 한두 번 뜹니다.

```bash
./scripts/setup-signing.sh
./scripts/build-app.sh
```

서명서를 만든 뒤 첫 빌드에서는 손쉬운 사용 권한을 한 번 더 등록해야 합니다(아래 방법). 그 뒤로는 유지됩니다.

이 앱은 정식 개발자 서명 없이 ad-hoc 서명하므로, 다시 빌드하면 macOS가 다른 앱으로 취급해 손쉬운 사용 권한이 무효화됩니다. 시스템 설정에는 켜진 것으로 보여도 실제로는 권한이 없습니다. 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 DesktopNamer를 선택해 빼기(-) 버튼으로 지운 뒤, 앱을 다시 실행해 새로 추가하세요. 메뉴의 `문제 진단…`에서 현재 권한 상태와 Mission Control 감지 결과를 볼 수 있습니다.

## 알려진 제한

- 이름표는 원래 라벨을 "덮는" 것이므로 위치가 어긋나면 `MissionControlOverlay.swift`의 `labelBottomInset` 값을 조정하세요.
- 메뉴에서 데스크탑 전환은 macOS 단축키(⌃1~⌃9, ⌃0)를 대신 눌러 주는 방식입니다. 시스템 설정 > 키보드 > 키보드 단축키 > Mission Control에서 "데스크탑 N으로 전환"이 켜져 있어야 하고, 접근성 권한이 필요합니다. 11번째 이후 데스크탑은 메뉴에서 전환할 수 없습니다.
- 비공개 API로 공간을 직접 바꾸는 방식(`CGSManagedDisplaySetCurrentSpace`)은 Dock과 상태가 어긋나 창이 다른 데스크탑에 나타나는 문제가 있어 사용하지 않습니다.
- 전체 화면 앱 공간은 이름을 지정할 수 없습니다(Mission Control이 앱 이름을 표시).
