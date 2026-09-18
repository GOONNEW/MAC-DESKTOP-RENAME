import AppKit
import ApplicationServices

/// Mission Control 위쪽 "공간 막대(Spaces Bar)"를 접근성(AX) 트리에서 읽는다.
///
/// 예전에 이 방식을 포기했던 이유는 Dock의 트리가 비어 있었기 때문인데, 원인을 찾았다.
/// macOS 27에서 Mission Control의 접근성 트리가 **Dock에서 WindowManager로 옮겨갔다.**
/// Dock에는 자식이 0개인 빈 껍데기(mc 그룹)만 남아 있어서, Dock만 보면 아무것도 못 찾는다.
///
///     AXApplication "WindowManager"          ← macOS 27
///       AXGroup id=mc.display
///         AXButton …                         창 썸네일
///         AXGroup "Spaces Bar" id=mc.spaces
///           AXList id=mc.spaces.list
///             AXButton "데스크탑 1"          ← 우리가 원하는 것
///
/// macOS 26 이하에서는 같은 구조가 Dock 아래에 있다. 그래서 둘 다 찾아본다.
///
/// 이걸로 두 가지를 한 번에 해결한다.
/// 1. Mission Control이 열렸는지 **추측이 아니라 확인**할 수 있다.
/// 2. 각 데스크탑 썸네일의 정확한 위치를 알 수 있어, 그 위에 이름을 덧그릴 수 있다.
///    지금 보고 있는 데스크탑의 썸네일은 화면을 미리 찍은 것이라 안쪽에 둔 이름표가
///    안 찍히는데, 위에 덧그리면 그 문제가 사라진다.
enum SpacesBarAX {
    struct SpaceButton {
        /// AppKit 좌표계(왼쪽 아래가 원점)로 변환한 화면 위 위치
        let frame: CGRect
        /// Mission Control이 붙인 이름 (예: "데스크탑 3", "Safari")
        let label: String
        /// 이름 끝의 숫자. 기본 이름일 때 데스크탑 번호를 뜻한다.
        var number: Int? {
            let digits = label.reversed().prefix { $0.isNumber }
            guard !digits.isEmpty else { return nil }
            return Int(String(digits.reversed()))
        }
    }

    struct Scan {
        /// Mission Control이 열려 있으면 공간 버튼 목록. 닫혀 있으면 빈 배열.
        let buttons: [SpaceButton]
        /// 트리를 찾은 프로세스 이름 (진단용)
        let source: String
        let note: String
    }

    /// 트리를 찾아볼 프로세스. 앞쪽부터 시도한다.
    private static let hosts = [
        (bundleID: "com.apple.WindowManager", name: "WindowManager"),
        (bundleID: "com.apple.dock", name: "Dock"),
    ]

    /// 마지막으로 트리를 찾은 프로세스를 기억해 두고 먼저 시도한다
    private static var lastGoodHost: String?

    // MARK: - 빠른 확인

    /// Mission Control이 열려 있는지만 가볍게 본다.
    /// 트리 전체를 훑지 않고, 앱의 바로 아래 자식에 "mc"로 시작하는 그룹이 있는지만 본다.
    static func isOpen() -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        var sawHost = false
        for host in orderedHosts() {
            guard let app = application(for: host.bundleID) else { continue }
            sawHost = true
            guard let children = attribute(app, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for child in children where (identifier(of: child) ?? "").hasPrefix("mc") {
                // Dock에는 자식이 0개인 빈 껍데기만 남는 경우가 있어, 내용까지 확인한다
                if hasContent(child) {
                    lastGoodHost = host.bundleID
                    return true
                }
            }
        }
        return sawHost ? false : nil
    }

    /// mc 그룹이 진짜 내용을 담고 있는지 (빈 껍데기 걸러내기)
    private static func hasContent(_ element: AXUIElement) -> Bool {
        guard let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement], !children.isEmpty else {
            return false
        }
        if let f = rawFrame(of: element), f.width < 1 || f.height < 1 { return false }
        return true
    }

    // MARK: - 자세히 읽기

    static func scan() -> Scan {
        guard AXIsProcessTrusted() else {
            return Scan(buttons: [], source: "-", note: "접근성 권한 없음")
        }
        var notes: [String] = []
        for host in orderedHosts() {
            guard let app = application(for: host.bundleID) else {
                notes.append("\(host.name) 프로세스 없음")
                continue
            }
            guard let children = attribute(app, kAXChildrenAttribute) as? [AXUIElement] else {
                notes.append("\(host.name) 트리를 읽지 못함")
                continue
            }
            let groups = children.filter { (identifier(of: $0) ?? "").hasPrefix("mc") }
            guard !groups.isEmpty else {
                notes.append("\(host.name)에 mc 그룹 없음")
                continue
            }
            var buttons: [SpaceButton] = []
            for group in groups {
                guard let list = findDescendant(of: group, identifier: "mc.spaces.list", maxDepth: 6)
                    ?? findDescendant(of: group, identifier: "mc.spaces", maxDepth: 6) else { continue }
                for item in listItems(of: list) {
                    guard let rect = frame(of: item) else { continue }
                    let label = (attribute(item, kAXDescriptionAttribute) as? String)
                        ?? (attribute(item, kAXTitleAttribute) as? String)
                        ?? ""
                    buttons.append(SpaceButton(frame: rect, label: label))
                }
            }
            if !buttons.isEmpty {
                lastGoodHost = host.bundleID
                return Scan(buttons: buttons, source: host.name, note: "공간 버튼 \(buttons.count)개")
            }
            notes.append("\(host.name)의 mc 그룹에서 공간 버튼을 찾지 못함")
        }
        return Scan(buttons: [], source: "-", note: notes.joined(separator: "; "))
    }

    /// 목록 안의 버튼들. AXList 아래에 바로 있을 수도, 한 겹 더 들어가 있을 수도 있다.
    private static func listItems(of list: AXUIElement) -> [AXUIElement] {
        guard let children = attribute(list, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        let buttons = children.filter { (attribute($0, kAXRoleAttribute) as? String) == kAXButtonRole }
        if !buttons.isEmpty { return buttons }
        // 버튼이 한 겹 더 안쪽에 있는 경우
        return children.flatMap { (attribute($0, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
            .filter { (attribute($0, kAXRoleAttribute) as? String) == kAXButtonRole }
    }

    private static func orderedHosts() -> [(bundleID: String, name: String)] {
        guard let lastGoodHost else { return hosts }
        return hosts.sorted { first, _ in first.bundleID == lastGoodHost }
    }

    private static func application(for bundleID: String) -> AXUIElement? {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return nil
        }
        return AXUIElementCreateApplication(running.processIdentifier)
    }

    // MARK: - 진단

    /// 두 프로세스의 트리를 그대로 찍어 준다. 구조가 또 바뀌면 이걸 보고 맞춘다.
    static func treeDump(maxLines: Int = 80) -> String {
        guard AXIsProcessTrusted() else { return "접근성 권한이 없어 트리를 읽을 수 없습니다." }
        var lines: [String] = []
        for host in hosts {
            guard let app = application(for: host.bundleID) else {
                lines.append("\(host.name): 프로세스 없음")
                continue
            }
            let children = attribute(app, kAXChildrenAttribute) as? [AXUIElement] ?? []
            let ids = children.map { identifier(of: $0) ?? (attribute($0, kAXRoleAttribute) as? String ?? "?") }
            lines.append("\(host.name): 최상위 \(children.count)개 [\(ids.prefix(12).joined(separator: ", "))]")
            for group in children where (identifier(of: group) ?? "").hasPrefix("mc") {
                dump(group, depth: 1, maxDepth: 5, limit: maxLines, into: &lines)
            }
            if lines.count > maxLines { break }
        }
        return lines.prefix(maxLines).joined(separator: "\n")
    }

    private static func dump(_ element: AXUIElement, depth: Int, maxDepth: Int, limit: Int, into lines: inout [String]) {
        guard lines.count < limit else { return }
        let role = attribute(element, kAXRoleAttribute) as? String ?? "?"
        let id = identifier(of: element) ?? ""
        let description = attribute(element, kAXDescriptionAttribute) as? String ?? ""
        let title = attribute(element, kAXTitleAttribute) as? String ?? ""
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        var text = String(repeating: "  ", count: depth) + role
        if !id.isEmpty { text += " id=\(id)" }
        if !description.isEmpty { text += " desc=\"\(description)\"" }
        if !title.isEmpty { text += " title=\"\(title)\"" }
        if let f = rawFrame(of: element) {
            text += " (\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)))"
        }
        if !children.isEmpty { text += " 자식 \(children.count)" }
        lines.append(text)
        guard depth < maxDepth else { return }
        for child in children.prefix(12) {
            dump(child, depth: depth + 1, maxDepth: maxDepth, limit: limit, into: &lines)
        }
    }

    // MARK: - AX 도우미

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func identifier(of element: AXUIElement) -> String? {
        attribute(element, kAXIdentifierAttribute) as? String
    }

    private static func findDescendant(of element: AXUIElement, identifier target: String, maxDepth: Int) -> AXUIElement? {
        if identifier(of: element) == target { return element }
        guard maxDepth > 0, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findDescendant(of: child, identifier: target, maxDepth: maxDepth - 1) { return found }
        }
        return nil
    }

    /// AX가 주는 그대로의 위치 (왼쪽 위가 원점)
    private static func rawFrame(of element: AXUIElement) -> CGRect? {
        guard let posRef = attribute(element, kAXPositionAttribute),
              let sizeRef = attribute(element, kAXSizeAttribute),
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// AppKit 좌표(왼쪽 아래가 원점)로 뒤집은 위치
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let raw = rawFrame(of: element),
              let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        return CGRect(x: raw.minX, y: primaryHeight - raw.minY - raw.height,
                      width: raw.width, height: raw.height)
    }
}
