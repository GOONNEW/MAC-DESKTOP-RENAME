import AppKit

/// Mission Control이 열리면 각 데스크탑 썸네일 아래 라벨 자리에 사용자 지정 이름을 덮어 그린다.
final class MissionControlOverlay {
    private let spaces: SpaceManager
    private let names: NameStore

    private struct Label: Equatable {
        let frame: CGRect
        let text: String
    }

    private var timer: Timer?
    private var panels: [NSPanel] = []
    private var isShowing = false
    private var currentLabels: [Label] = []

    // 진단 정보
    private var lastDetection: Date?
    private var lastScanNote = "아직 실행 안 됨"
    private var lastButtons: [DockAccessibility.SpaceButton] = []
    private var lastLabelNote = ""
    private var tickCount = 0

    /// 버튼 프레임 바닥에서 라벨 중심까지의 거리. Mission Control의 라벨 위치에 맞춰 조정한다.
    private let labelBottomInset: CGFloat = 12
    private let labelHeight: CGFloat = 22

    init(spaces: SpaceManager, names: NameStore) {
        self.spaces = spaces
        self.names = names
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        if !DockAccessibility.isTrusted {
            DockAccessibility.requestTrust()
            Self.showPermissionHelp()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer?.tolerance = 0.05
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hide()
    }

    private func tick() {
        tickCount += 1
        guard DockAccessibility.isTrusted else {
            lastScanNote = "접근성 권한 없음"
            if isShowing { hide() }
            return
        }
        let scan = DockAccessibility.scan()
        guard let buttons = scan.buttons else {
            // Mission Control이 닫혀 있는 평소 상태. 마지막 감지 기록은 유지한다.
            if isShowing {
                hide()
                lastScanNote = scan.note
            }
            return
        }
        lastDetection = Date()
        lastScanNote = scan.note
        lastButtons = buttons
        show(buttons)
    }

    /// 사용자가 붙여넣어 보낼 수 있는 진단 텍스트
    func diagnostics() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        var lines: [String] = []
        lines.append("접근성 권한: \(DockAccessibility.isTrusted ? "허용됨" : "없음 (시스템 설정에서 DesktopNamer를 지운 뒤 다시 추가)")")
        lines.append("오버레이 실행 중: \(isRunning ? "예" : "아니오") (검사 \(tickCount)회)")
        lines.append("Mission Control 마지막 감지: \(lastDetection.map { formatter.string(from: $0) } ?? "없음")")
        lines.append("마지막 검사 메모: \(lastScanNote)")
        if !lastButtons.isEmpty {
            lines.append("감지된 버튼:")
            for button in lastButtons {
                let f = button.frame
                let number = button.number.map { String($0) } ?? "-"
                lines.append("  \(button.description) → 번호 \(number), 위치 (\(Int(f.minX)), \(Int(f.minY))) 크기 \(Int(f.width))×\(Int(f.height))")
            }
        }
        lines.append("그린 이름표: \(lastLabelNote.isEmpty ? "없음" : lastLabelNote)")
        lines.append("이름 저장 목록: \(names.names.isEmpty ? "없음" : names.names.values.joined(separator: ", "))")
        lines.append("공간 목록: " + spaces.spaces.map { $0.number.map { String($0) } ?? "전체화면" }.joined(separator: ", "))
        lines.append("화면: " + NSScreen.screens.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) @ (\(Int($0.frame.minX)), \(Int($0.frame.minY)))" }.joined(separator: " / "))
        return lines.joined(separator: "\n")
    }

    static func showPermissionHelp() {
        let alert = NSAlert()
        alert.messageText = "손쉬운 사용 권한이 필요합니다"
        alert.informativeText = "Mission Control에 이름을 표시하려면 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 DesktopNamer를 켜야 합니다.\n\n이미 켜져 있는데도 이 창이 뜬다면, 앱을 다시 빌드해서 권한이 무효화된 것입니다. 목록에서 DesktopNamer를 선택하고 빼기(-) 버튼으로 지운 뒤, 앱을 다시 실행해서 새로 추가하세요."
        alert.addButton(withTitle: "확인")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func show(_ buttons: [DockAccessibility.SpaceButton]) {
        let byNumber = Dictionary(
            spaces.spaces.compactMap { space in space.number.map { ($0, space) } },
            uniquingKeysWith: { first, _ in first }
        )

        var labels: [Label] = []
        for button in buttons {
            guard let number = button.number, let space = byNumber[number],
                  let custom = names.customName(for: space) else { continue }
            let frame = CGRect(
                x: button.frame.minX,
                y: button.frame.minY + labelBottomInset - labelHeight / 2,
                width: button.frame.width,
                height: labelHeight
            )
            labels.append(Label(frame: frame, text: custom))
        }

        lastLabelNote = labels.isEmpty
            ? "없음 (버튼 \(buttons.count)개 중 이름이 지정된 데스크탑과 번호가 맞는 것이 없음)"
            : labels.map { "\($0.text) @ (\(Int($0.frame.minX)), \(Int($0.frame.minY)))" }.joined(separator: ", ")
        if labels != currentLabels || !isShowing {
            rebuildPanels(with: labels)
            currentLabels = labels
        }
        isShowing = true
    }

    private func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        currentLabels = []
        isShowing = false
    }

    private func rebuildPanels(with labels: [Label]) {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()

        for screen in NSScreen.screens {
            let onThisScreen = labels.filter { screen.frame.intersects($0.frame) }
            guard !onThisScreen.isEmpty else { continue }

            let panel = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

            let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            for label in onThisScreen {
                let local = CGRect(
                    x: label.frame.minX - screen.frame.minX,
                    y: label.frame.minY - screen.frame.minY,
                    width: label.frame.width,
                    height: label.frame.height
                )
                container.addSubview(Self.makeLabel(text: label.text, in: local))
            }
            panel.contentView = container
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    /// 어두운 반투명 알약 배경 위에 흰 글씨. 원래 "데스크탑 N" 글자 위를 덮는다.
    private static func makeLabel(text: String, in area: CGRect) -> NSView {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.textColor = .white
        field.alignment = .center
        field.lineBreakMode = .byTruncatingTail
        field.sizeToFit()

        let padding: CGFloat = 10
        let width = min(field.frame.width + padding * 2, area.width)
        let pill = NSView(frame: CGRect(
            x: area.midX - width / 2,
            y: area.minY,
            width: width,
            height: area.height
        ))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.78).cgColor
        pill.layer?.cornerRadius = 6

        field.frame = pill.bounds.insetBy(dx: padding, dy: 0)
        pill.addSubview(field)
        return pill
    }
}
