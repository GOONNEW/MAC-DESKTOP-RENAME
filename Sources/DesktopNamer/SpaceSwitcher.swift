import AppKit
import CoreGraphics

/// 데스크탑 전환. 비공개 API로 직접 바꾸면 Dock이 모르는 사이에 공간이 바뀌어 상태가 꼬일 수 있으므로,
/// macOS 자체 단축키(⌃1 ~ ⌃9, ⌃0 = 데스크탑 10)를 대신 눌러 주는 방식만 사용한다.
/// 시스템 설정 > 키보드 > 키보드 단축키 > Mission Control에서 "데스크탑 N으로 전환"이 켜져 있어야 한다.
enum SpaceSwitcher {
    private static let keyCodes: [Int: CGKeyCode] = [
        1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25, 10: 29,
    ]

    static func canSwitch(to number: Int) -> Bool {
        keyCodes[number] != nil
    }

    /// 성공하면 true. 접근성 권한이 없으면 요청 창을 띄우고 false.
    @discardableResult
    static func switchTo(number: Int) -> Bool {
        guard let keyCode = keyCodes[number] else { return false }
        guard DockAccessibility.isTrusted else {
            DockAccessibility.requestTrust()
            return false
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.flags = .maskControl
        up.flags = .maskControl
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
