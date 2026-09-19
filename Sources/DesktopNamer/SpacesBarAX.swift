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
        /// AppKit 좌표계(왼쪽 아래가 원점)로 변환하고 크기를 바로잡은 위치
        let frame: CGRect
        /// 접근성이 알려준 그대로의 값 (진단용)
        let rawFrame: CGRect
        /// 크기에 곱한 보정 배율 (진단용)
        let scale: CGFloat
        /// Mission Control이 붙인 이름 (예: "exit to 데스크탑 3", "exit to full screen Safari")
        let label: String

        /// 이름 끝의 숫자. 기본 이름일 때 데스크탑 번호를 뜻한다.
        ///
        /// 전체 화면 공간은 "exit to full screen Windows 11"처럼 앱 이름에 숫자가 들어 있어
        /// 데스크탑 번호로 오해할 수 있다. 그런 항목은 번호로 보지 않는다.
        var number: Int? {
            guard !label.lowercased().contains("full screen") else { return nil }
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
            // 목록(= 디스플레이)별로 모은다
            var perList: [[(label: String, raw: CGRect, element: AXUIElement)]] = []
            for group in groups {
                guard let list = findDescendant(of: group, identifier: "mc.spaces.list", maxDepth: 6)
                    ?? findDescendant(of: group, identifier: "mc.spaces", maxDepth: 6) else { continue }
                var items: [(label: String, raw: CGRect, element: AXUIElement)] = []
                for item in listItems(of: list) {
                    guard let raw = rawFrame(of: item) else { continue }
                    let label = (attribute(item, kAXDescriptionAttribute) as? String)
                        ?? (attribute(item, kAXTitleAttribute) as? String)
                        ?? ""
                    items.append((label, raw, item))
                }
                if !items.isEmpty { perList.append(items) }
            }

            // 미션 컨트롤이 열리고 닫히는 동안에는 공간 막대가 가운데에서 펼쳐진다.
            // 그 중간 모습은 버튼 간격이 실제의 절반이라, 크기 배율을 잘못 알아내게 만든다.
            // (간격 85에 너비 169 → 두 배로 오판. 다 펼쳐지면 간격 171, 너비 169로 딱 맞는다)
            // 그래서 두 번 연속 같은 자리에 있을 때(= 움직임이 멈췄을 때)만 배율을 배운다.
            let signature = perList.flatMap { $0 }
                .map { "\(Int($0.raw.minX)),\(Int($0.raw.minY)),\(Int($0.raw.width))" }
                .joined(separator: "|")
            let stable = !signature.isEmpty && signature == previousSignature
            previousSignature = signature

            let scale = sizeScale(for: perList.flatMap { $0.map(\.raw) }, stable: stable)

            var buttons: [SpaceButton] = []
            for items in perList {
                for item in items {
                    let corrected = CGRect(x: item.raw.minX, y: item.raw.minY,
                                           width: item.raw.width * scale, height: item.raw.height * scale)
                    guard let flipped = flip(corrected) else { continue }
                    buttons.append(SpaceButton(frame: flipped, rawFrame: item.raw,
                                               scale: scale, label: item.label))
                }
            }
            if !buttons.isEmpty {
                lastGoodHost = host.bundleID
                rememberWhileOpen(host: host.name, groups: groups, buttons: buttons,
                                  sample: perList.first?.first?.element, stable: stable)
                return Scan(buttons: buttons, source: host.name, note: "공간 버튼 \(buttons.count)개")
            }
            notes.append("\(host.name)의 mc 그룹에서 공간 버튼을 찾지 못함")
        }
        return Scan(buttons: [], source: "-", note: notes.joined(separator: "; "))
    }

    /// 크기 보정 배율을 알아낸다.
    ///
    /// 접근성이 **위치는 포인트로, 크기는 픽셀로** 알려주는 경우가 있다. 레티나 화면에서는
    /// 크기가 실제의 두 배가 되어, 이름표가 썸네일 바깥(오른쪽 아래)으로 밀려난다.
    /// 실제로 이 맥에서 버튼 간격은 85pt인데 너비를 169pt로 알려주었다. 그대로 믿으면
    /// 버튼끼리 절반씩 겹친다는 뜻이 되어 앞뒤가 맞지 않는다.
    ///
    /// 그래서 숫자를 미리 정하지 않고, 버튼들이 늘어선 간격과 너비를 비교해 알아낸다.
    /// 나란히 놓인 썸네일의 너비는 간격보다 클 수 없다.
    private static func sizeScale(for frames: [CGRect], stable: Bool) -> CGFloat {
        if stable, let detected = detectScale(for: frames) {
            learnedScale = detected
            return detected
        }
        // 아직 움직이는 중이면 새로 재지 않고, 지난번에 안정된 상태에서 알아낸 값을 쓴다.
        return learnedScale ?? 1
    }

    /// 한 번 알아낸 크기 배율
    private static var learnedScale: CGFloat?

    private static func detectScale(for frames: [CGRect]) -> CGFloat? {
        let sorted = frames.sorted { $0.minX < $1.minX }
        guard sorted.count >= 3 else { return nil }
        var pitches: [CGFloat] = []
        for (left, right) in zip(sorted, sorted.dropFirst()) {
            pitches.append(right.minX - left.minX)
        }
        pitches.sort()
        let pitch = pitches[pitches.count / 2]
        let width = sorted[sorted.count / 2].width
        guard pitch > 1, width > 0 else { return nil }
        let factor = (width / pitch).rounded()
        return factor >= 2 ? 1 / factor : 1
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

    /// Mission Control이 열려 있을 때 본 마지막 모습.
    ///
    /// mc 그룹은 열려 있는 동안에만 존재한다. 그래서 메뉴에서 진단을 열면(= 닫힌 상태)
    /// 트리가 늘 비어 있어 아무것도 확인할 수 없었다. 열렸을 때 한 번 찍어 둔다.
    private(set) static var lastOpenSnapshot: String?
    private static var lastOpenButtonCount = 0
    private static var lastTreeDump: [String] = []

    private static var previousSignature = ""

    private static func rememberWhileOpen(host: String, groups: [AXUIElement], buttons: [SpaceButton],
                                          sample: AXUIElement?, stable: Bool) {
        guard stable else { return }
        // 멈춰 있는 동안에는 매번 갱신한다. 한 번만 찍어 두면 이름표를 놓은 기록과 서로 다른
        // 순간의 것이 되어 대조가 안 된다. 비싼 트리 덤프만 처음 한 번으로 아낀다.
        let needsTree = lastOpenSnapshot == nil || buttons.count != lastOpenButtonCount
        lastOpenButtonCount = buttons.count
        var lines: [String] = ["\(host)에서 읽음, 공간 버튼 \(buttons.count)개 (움직임이 멈춘 상태)"]
        for button in buttons {
            let f = button.frame
            let r = button.rawFrame
            lines.append("  \"\(button.label)\" 번호 \(button.number.map(String.init) ?? "-")"
                + " 원본 (\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
                + " ×\(String(format: "%.2f", button.scale))"
                + " → (\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)))")
        }
        // 버튼 하나의 속성과 자식을 전부 찍는다.
        // 버튼 영역에는 썸네일 그림과 아래 글자, 여백이 함께 들어 있어 그림의 정확한 자리를
        // 알 수 없다. 자식 요소나 다른 속성에 그림만의 자리가 들어 있는지 확인하기 위함이다.
        if needsTree, let sample {
            var namesRef: CFArray?
            let names = AXUIElementCopyAttributeNames(sample, &namesRef) == .success
                ? (namesRef as? [String] ?? []) : []
            lines.append("버튼 속성: " + names.joined(separator: ", "))
            for key in ["AXFrame", "AXVisibleArea", "AXSelectedArea"] where names.contains(key) {
                if let value = attribute(sample, key), CFGetTypeID(value) == AXValueGetTypeID() {
                    var rect = CGRect.zero
                    if AXValueGetValue(value as! AXValue, .cgRect, &rect) {
                        lines.append("  \(key) = (\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height)))")
                    }
                }
            }
            let kids = attribute(sample, kAXChildrenAttribute) as? [AXUIElement] ?? []
            lines.append("버튼 자식 \(kids.count)개")
            for kid in kids.prefix(6) {
                dump(kid, depth: 1, maxDepth: 2, limit: 60, into: &lines)
            }
        }
        if needsTree {
            lines.append("트리:")
            for group in groups {
                dump(group, depth: 1, maxDepth: 5, limit: 70, into: &lines)
            }
            lastTreeDump = lines
        } else if !lastTreeDump.isEmpty {
            // 트리는 비싸서 처음 한 번만 찍는다. 그때의 좌표라는 점을 밝혀 둔다.
            lines.append("아래는 처음 열었을 때 찍어 둔 기록입니다 (좌표는 그때 값):")
            lines.append(contentsOf: lastTreeDump.drop { !$0.hasPrefix("버튼 속성") && $0 != "트리:" })
        }
        lastOpenSnapshot = lines.prefix(70).joined(separator: "\n")
    }

    /// 두 프로세스의 트리를 지금 그대로 찍어 준다. 구조가 또 바뀌면 이걸 보고 맞춘다.
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

    /// AppKit 좌표(왼쪽 아래가 원점)로 뒤집는다.
    /// 접근성 좌표의 원점은 주 화면의 왼쪽 위이므로, 주 화면 높이를 기준으로 한 번만 뒤집으면 된다.
    private static func flip(_ raw: CGRect) -> CGRect? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        return CGRect(x: raw.minX, y: primaryHeight - raw.minY - raw.height,
                      width: raw.width, height: raw.height)
    }
}
