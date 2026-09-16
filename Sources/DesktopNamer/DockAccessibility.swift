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

    /// 이 앱의 접근성 권한 기록을 모두 지운 뒤 다시 요청한다.
    /// 다시 빌드해서 오래된 항목이 남아 있을 때 쓴다. 결과 메시지를 돌려준다.
    static func resetTrustAndRequest() -> String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.desktopnamer"
        let output = run("/usr/bin/tccutil", ["reset", "Accessibility", bundleID])
        requestTrust()
        return output.isEmpty ? "권한 기록을 지웠습니다. 시스템 설정에서 DesktopNamer를 켜 주세요." : output
    }

    /// 앱 번들 위치와 코드 서명 정보 (진단용)
    static func signingInfo() -> String {
        let path = Bundle.main.bundlePath
        let output = run("/usr/bin/codesign", ["-dv", "--verbose=2", path])
        let interesting = output
            .split(separator: "\n")
            .filter { $0.hasPrefix("Identifier=") || $0.hasPrefix("Authority=") || $0.hasPrefix("Signature=") || $0.hasPrefix("CDHash=") }
            .joined(separator: " / ")
        return "\(path)\n서명: \(interesting.isEmpty ? output.trimmingCharacters(in: .whitespacesAndNewlines) : interesting)"
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "실행 실패: \(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    struct Scan {
        /// Mission Control이 열려 있으면 공간 버튼 목록, 아니면 nil.
        let buttons: [SpaceButton]?
        /// 진단용 메모
        let note: String
        /// 버튼을 못 찾았을 때 mc 그룹 아래 구조 덤프 (진단용)
        let tree: String
    }

    static func spaceButtons() -> [SpaceButton]? {
        scan().buttons
    }

    static func scan() -> Scan {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return Scan(buttons: nil, note: "Dock 프로세스를 찾지 못함", tree: "")
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var childrenRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &childrenRef)
        guard error == .success, let children = childrenRef as? [AXUIElement] else {
            return Scan(buttons: nil, note: "Dock 접근성 트리를 읽지 못함 (AXError \(error.rawValue))", tree: "")
        }

        let ids = children.map { identifier(of: $0) ?? "?" }
        let groups = children.filter { identifier(of: $0) == "mc" }
        guard !groups.isEmpty else {
            return Scan(buttons: nil, note: "Mission Control 그룹(mc) 없음. Dock 최상위 항목: \(ids.joined(separator: ", "))", tree: "")
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
        var lines: [String] = []
        for group in groups {
            dump(group, depth: 0, maxDepth: 6, into: &lines)
            if buttons.isEmpty { lines.append("  " + describeAttributes(of: group)) }
            if lines.count > 120 { break }
        }
        let tree = lines.prefix(120).joined(separator: "\n")
        return Scan(buttons: buttons, note: note, tree: tree)
    }

    /// Dock에 "확장 접근성" 신호를 보낸다. 일부 앱은 보조 기술이 이 신호를 보낼 때만 접근성 트리를 채운다.
    static func setEnhancedAccessibility(_ enabled: Bool) -> String {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return "Dock 없음"
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        let value: CFBoolean = enabled ? kCFBooleanTrue : kCFBooleanFalse
        let r1 = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, value)
        let r2 = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, value)
        return "AXEnhancedUserInterface=\(r1.rawValue), AXManualAccessibility=\(r2.rawValue)"
    }

    /// 요소가 가진 속성 이름과, 자식을 얻는 다른 경로들의 결과 (진단용)
    static func describeAttributes(of element: AXUIElement) -> String {
        var namesRef: CFArray?
        let names = AXUIElementCopyAttributeNames(element, &namesRef) == .success
            ? (namesRef as? [String] ?? []) : []
        var parts: [String] = ["속성: " + names.joined(separator: ", ")]
        for key in ["AXChildren", "AXVisibleChildren", "AXChildrenInNavigationOrder", "AXContents", "AXRows", "AXColumns"] {
            if let list = attribute(element, key) as? [AXUIElement] {
                parts.append("\(key)=\(list.count)개")
            }
        }
        return parts.joined(separator: " / ")
    }

    /// Dock이 화면에 띄운 창 목록. Mission Control이 열리면 화면 크기의 Dock 창이 생기므로 감지 신호로 쓴다.
    static func dockWindows() -> [(name: String, frame: CGRect, layer: Int)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard (info[kCGWindowOwnerName as String] as? String) == "Dock",
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
            let name = info[kCGWindowName as String] as? String ?? ""
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            return (name, bounds, layer)
        }
    }

    /// 화면을 거의 다 덮는 Dock 창이 있으면 true. (일부 macOS는 Mission Control이 닫혀도 이런 창을 유지하므로 단독 판정에는 쓰지 않는다)
    static func isMissionControlLikelyOpen() -> Bool {
        guard let screen = NSScreen.screens.first else { return false }
        let minArea = screen.frame.width * screen.frame.height * 0.8
        return dockWindows().contains { $0.frame.width * $0.frame.height >= minArea }
    }

    /// 시스템(Window Server)이 띄운 화면 위 창 목록. Mission Control이 열리면 메뉴 막대(Menubar) 창이 사라진다.
    static func windowServerWindows() -> [(name: String, frame: CGRect, layer: Int)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard (info[kCGWindowOwnerName as String] as? String) == "Window Server",
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
            let name = info[kCGWindowName as String] as? String ?? ""
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            return (name, bounds, layer)
        }
    }

    static func windowServerSignature() -> String {
        windowServerWindows()
            .map { "\($0.name.isEmpty ? "(이름 없음)" : $0.name) \(Int($0.frame.width))×\(Int($0.frame.height))@\(Int($0.frame.minX)),\(Int($0.frame.minY)) L\($0.layer)" }
            .sorted()
            .joined(separator: " | ")
    }

    /// 메뉴 막대 창이 화면에 보이는지
    static func isMenuBarVisible() -> Bool {
        windowServerWindows().contains { $0.name == "Menubar" }
    }

    /// Dock 창 목록을 비교 가능한 문자열로 만든다. Mission Control이 열리면 이 값이 평소와 달라진다.
    static func dockWindowSignature() -> String {
        dockWindows()
            .map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.frame.minX)),\(Int($0.frame.minY))/L\($0.layer)/\($0.name)" }
            .sorted()
            .joined(separator: " | ")
    }

    /// 접근성 요소의 역할/식별자/설명/위치를 들여쓰기로 기록한다.
    private static func dump(_ element: AXUIElement, depth: Int, maxDepth: Int, into lines: inout [String]) {
        guard lines.count <= 120 else { return }
        let role = attribute(element, kAXRoleAttribute) as? String ?? "?"
        let id = identifier(of: element) ?? ""
        let description = attribute(element, kAXDescriptionAttribute) as? String ?? ""
        let title = attribute(element, kAXTitleAttribute) as? String ?? ""
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        var text = String(repeating: "  ", count: depth) + role
        if !id.isEmpty { text += " id=\(id)" }
        if !description.isEmpty { text += " desc=\"\(description)\"" }
        if !title.isEmpty { text += " title=\"\(title)\"" }
        if let f = frame(of: element) {
            text += " (\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)))"
        }
        if !children.isEmpty { text += " 자식 \(children.count)" }
        lines.append(text)
        guard depth < maxDepth else { return }
        for child in children.prefix(15) {
            dump(child, depth: depth + 1, maxDepth: maxDepth, into: &lines)
        }
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
