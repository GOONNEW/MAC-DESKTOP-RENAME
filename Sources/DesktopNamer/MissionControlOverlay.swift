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

    /// 버튼 프레임 바닥에서 라벨 중심까지의 거리. Mission Control의 라벨 위치에 맞춰 조정한다.
    private let labelBottomInset: CGFloat = 12
    private let labelHeight: CGFloat = 22

    init(spaces: SpaceManager, names: NameStore) {
        self.spaces = spaces
        self.names = names
    }

    func start() {
        guard timer == nil else { return }
        if !DockAccessibility.isTrusted {
            DockAccessibility.requestTrust()
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
        guard DockAccessibility.isTrusted, let buttons = DockAccessibility.spaceButtons() else {
            if isShowing { hide() }
            return
        }
        show(buttons)
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
