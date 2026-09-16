import AppKit
import ApplicationServices

/// Mission Control이 열려 있을 때 Dock의 접근성 트리에서 공간 버튼(썸네일+라벨)의 위치를 읽는다.
/// Dock은 Mission Control 중에 식별자 "mc" 그룹을 노출하고, 그 안의 "mc.spaces.list"에 공간 버튼이 있다.
enum DockAccessibility {
    struct SpaceButton {
        /// AppKit 좌표계(왼쪽 아래 원점)로 변환된 화면 좌표
        let frame: CGRect
        /// Mission Control이 붙인 설명 (예: "데스크탑 3", "Safari")
        let description: String
        /// 설명 끝의 숫자. 기본 이름의 데스크탑 번호를 뜻한다.
        var number: Int? {
            let digits = description.reversed().prefix { $0.isNumber }
            guard !digits.isEmpty, let n = Int(String(digits.reversed())) else { return nil }
            return n
        }
    }

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 접근성 권한을 요청한다. 시스템 설정 안내 대화상자가 뜬다.
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    struct Scan {
        /// Mission Control이 열려 있으면 공간 버튼 목록, 아니면 nil.
        let buttons: [SpaceButton]?
        /// 진단용 메모
        let note: String
    }

    static func spaceButtons() -> [SpaceButton]? {
        scan().buttons
    }

    static func scan() -> Scan {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return Scan(buttons: nil, note: "Dock 프로세스를 찾지 못함")
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var childrenRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &childrenRef)
        guard error == .success, let children = childrenRef as? [AXUIElement] else {
            return Scan(buttons: nil, note: "Dock 접근성 트리를 읽지 못함 (AXError \(error.rawValue))")
        }

        let ids = children.map { identifier(of: $0) ?? "?" }
        let groups = children.filter { identifier(of: $0) == "mc" }
        guard !groups.isEmpty else {
            return Scan(buttons: nil, note: "Mission Control 그룹(mc) 없음. Dock 최상위 항목: \(ids.joined(separator: ", "))")
        }

        var buttons: [SpaceButton] = []
        var notes: [String] = []
        for group in groups {
            guard let list = findDescendant(of: group, identifier: "mc.spaces.list", maxDepth: 4) else {
                notes.append("mc 그룹 안에서 mc.spaces.list를 찾지 못함")
                continue
            }
            guard let items = attribute(list, kAXChildrenAttribute) as? [AXUIElement] else {
                notes.append("mc.spaces.list의 자식을 읽지 못함")
                continue
            }
            for item in items {
                guard let rect = frame(of: item) else {
                    notes.append("버튼 위치를 읽지 못함")
                    continue
                }
                let description = attribute(item, kAXDescriptionAttribute) as? String ?? ""
                buttons.append(SpaceButton(frame: rect, description: description))
            }
        }
        let note = notes.isEmpty ? "mc 그룹 \(groups.count)개, 버튼 \(buttons.count)개" : notes.joined(separator: "; ")
        return Scan(buttons: buttons, note: note)
    }

    // MARK: - AX helpers

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    private static func identifier(of element: AXUIElement) -> String? {
        attribute(element, kAXIdentifierAttribute) as? String
    }

    private static func findDescendant(of element: AXUIElement, identifier: String, maxDepth: Int) -> AXUIElement? {
        guard maxDepth >= 0 else { return nil }
        if self.identifier(of: element) == identifier { return element }
        guard maxDepth > 0, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findDescendant(of: child, identifier: identifier, maxDepth: maxDepth - 1) {
                return found
            }
        }
        return nil
    }

    /// AX 좌표(왼쪽 위 원점, 주 화면 기준)를 AppKit 좌표로 변환한 프레임
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let posRef = attribute(element, kAXPositionAttribute),
              let sizeRef = attribute(element, kAXSizeAttribute),
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }

        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let flippedY = primaryHeight - position.y - size.height
        return CGRect(x: position.x, y: flippedY, width: size.width, height: size.height)
    }
}
