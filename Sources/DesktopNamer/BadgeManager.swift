import AppKit
import Combine

/// 데스크탑마다 "이름 배지" 창을 하나씩 둔다.
///
/// 배지는 평소엔 완전히 투명해서 보이지 않고, Mission Control이 열릴 것 같은 순간에만 보이게 바꾼다.
/// Mission Control 썸네일은 각 데스크탑을 실시간으로 축소해 보여주므로, 배지가 썸네일 안에 이름으로 나타난다.
/// 창은 그 데스크탑이 활성일 때 만들어야 그 데스크탑에 속하므로, 데스크탑을 방문할 때마다 없는 배지를 만든다.
final class BadgeManager {
    enum Corner: String, CaseIterable {
        case bottomRight, bottomLeft, topRight, topLeft

        var title: String {
            switch self {
            case .bottomRight: return "오른쪽 아래"
            case .bottomLeft: return "왼쪽 아래"
            case .topRight: return "오른쪽 위"
            case .topLeft: return "왼쪽 위"
            }
        }
    }

    private let spaces: SpaceManager
    private let names: NameStore

    /// 공간 UUID → 화면마다 하나씩인 배지 창들
    private var badges: [String: [NSPanel]] = [:]
    private var fields: [String: [NSTextField]] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var running = false
    private(set) var isVisible = false
    private var hideTimer: Timer?
    private var events: [String] = []

    var corner: Corner = .bottomRight {
        didSet { badges.keys.forEach { layout(uuid: $0) } }
    }

    /// 글자 크기. Mission Control 썸네일(약 1/12)에서 읽히려면 커야 한다.
    private let fontSize: CGFloat = 64
    private let margin = CGSize(width: 40, height: 96) // 아래쪽은 Dock 자리를 피한다

    init(spaces: SpaceManager, names: NameStore) {
        self.spaces = spaces
        self.names = names
    }

    var isRunning: Bool { running }

    func start() {
        guard !running else { return }
        running = true

        // 활성 데스크탑이 바뀔 때마다 그 데스크탑의 배지를 준비한다
        spaces.$activeSpace
            .compactMap { $0 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] space in self?.ensureBadge(for: space) }
            .store(in: &cancellables)

        // 이름이 바뀌면 글자를 갱신한다
        names.$names
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshTexts() }
            .store(in: &cancellables)

        // 사라진 데스크탑의 배지는 닫는다
        spaces.$spaces
            .map { Set($0.map(\.uuid)) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] uuids in self?.removeBadges(notIn: uuids) }
            .store(in: &cancellables)

        if let active = spaces.activeSpace { ensureBadge(for: active) }
    }

    func stop() {
        running = false
        cancellables.removeAll()
        hideTimer?.invalidate()
        badges.values.forEach { $0.forEach { $0.orderOut(nil) } }
        badges.removeAll()
        fields.removeAll()
        isVisible = false
    }

    // MARK: - 보이기/숨기기

    /// Mission Control이 열릴 것 같을 때: 잠깐 뒤(애니메이션이 시작될 즈음) 배지를 보이게 한다.
    func show(reason: String) {
        guard running else { return }
        hideTimer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.running else { return }
            self.setVisible(true)
            self.log("표시 (\(reason))")
        }
        // 닫힘 신호를 놓쳐도 배지가 영원히 남지 않도록
        hideTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.hide(reason: "시간 초과")
        }
    }

    func hide(reason: String) {
        guard isVisible else { return }
        hideTimer?.invalidate()
        setVisible(false)
        log("숨김 (\(reason))")
    }

    private func setVisible(_ visible: Bool) {
        isVisible = visible
        for (uuid, panels) in badges {
            let alpha: CGFloat = visible && hasName(uuid) ? 1 : 0
            panels.forEach { $0.alphaValue = alpha }
        }
    }

    /// 5초 동안 배지를 보여 준다 (제대로 뜨는지 눈으로 확인용)
    func preview() {
        guard running else { return }
        hideTimer?.invalidate()
        setVisible(true)
        log("미리 보기")
        hideTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.hide(reason: "미리 보기 종료")
        }
    }

    private func hasName(_ uuid: String) -> Bool {
        guard let space = spaces.spaces.first(where: { $0.uuid == uuid }) else { return false }
        return names.customName(for: space) != nil
    }

    // MARK: - 배지 창

    private func ensureBadge(for space: Space) {
        guard running, space.isActive, !space.isFullscreen, badges[space.uuid] == nil else { return }
        var panels: [NSPanel] = []
        var texts: [NSTextField] = []
        for screen in NSScreen.screens {
            let (panel, field) = makePanel(on: screen, text: names.displayName(for: space))
            panels.append(panel)
            texts.append(field)
        }
        guard !panels.isEmpty else { return }
        badges[space.uuid] = panels
        fields[space.uuid] = texts
        layout(uuid: space.uuid)
        if isVisible {
            let alpha: CGFloat = hasName(space.uuid) ? 1 : 0
            panels.forEach { $0.alphaValue = alpha }
        }
        log("배지 생성: \(space.defaultName) (화면 \(panels.count)개)")
    }

    private func makePanel(on screen: NSScreen, text: String) -> (NSPanel, NSTextField) {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: fontSize, weight: .heavy)
        field.textColor = .white
        field.alignment = .center
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1

        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.13, alpha: 0.85).cgColor
        container.layer?.cornerRadius = 22
        container.addSubview(field)

        let panel = NSPanel(
            contentRect: CGRect(x: screen.frame.minX, y: screen.frame.minY, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0
        panel.isReleasedWhenClosed = false
        // 창들 위에 떠서 썸네일에서 항상 보이게. 평소엔 투명이라 방해하지 않는다.
        panel.level = .floating
        // 이 데스크탑에만 속한다 (canJoinAllSpaces 없음)
        panel.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary, .managed]
        panel.contentView = container
        panel.orderFrontRegardless()
        return (panel, field)
    }

    private func refreshTexts() {
        for (uuid, texts) in fields {
            guard let space = spaces.spaces.first(where: { $0.uuid == uuid }) else { continue }
            texts.forEach { $0.stringValue = names.displayName(for: space) }
            layout(uuid: uuid)
            let alpha: CGFloat = isVisible && hasName(uuid) ? 1 : 0
            badges[uuid]?.forEach { $0.alphaValue = alpha }
        }
    }

    /// 글자 크기에 맞춰 배지 크기를 정하고 각 화면 구석에 놓는다
    private func layout(uuid: String) {
        guard let panels = badges[uuid], let texts = fields[uuid] else { return }
        for (index, panel) in panels.enumerated() {
            guard index < texts.count else { continue }
            let field = texts[index]
            let screen = panel.screen ?? NSScreen.screens[min(index, NSScreen.screens.count - 1)]
            field.sizeToFit()
            let paddingX: CGFloat = 34
            let paddingY: CGFloat = 16
            let maxWidth = screen.frame.width * 0.6
            let width = min(field.frame.width + paddingX * 2, maxWidth)
            let height = field.frame.height + paddingY * 2
            field.frame = CGRect(x: paddingX, y: paddingY, width: width - paddingX * 2, height: field.frame.height)
            panel.contentView?.frame = CGRect(x: 0, y: 0, width: width, height: height)

            let visible = screen.visibleFrame
            let full = screen.frame
            var origin = CGPoint.zero
            switch corner {
            case .bottomRight:
                origin = CGPoint(x: full.maxX - margin.width - width, y: full.minY + margin.height)
            case .bottomLeft:
                origin = CGPoint(x: full.minX + margin.width, y: full.minY + margin.height)
            case .topRight:
                origin = CGPoint(x: full.maxX - margin.width - width, y: visible.maxY - margin.width - height)
            case .topLeft:
                origin = CGPoint(x: full.minX + margin.width, y: visible.maxY - margin.width - height)
            }
            panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
        }
    }

    private func removeBadges(notIn uuids: Set<String>) {
        for (uuid, panels) in badges where !uuids.contains(uuid) {
            panels.forEach { $0.orderOut(nil) }
            badges.removeValue(forKey: uuid)
            fields.removeValue(forKey: uuid)
        }
    }

    // MARK: - 모든 데스크탑 준비

    /// 배지가 없는 데스크탑을 차례로 방문해 배지를 만들고 원래 자리로 돌아온다.
    func prepareAllBadges(completion: @escaping (String) -> Void) {
        guard running else { completion("배지 기능이 꺼져 있습니다."); return }
        let missing = spaces.spaces.filter { !$0.isFullscreen && badges[$0.uuid] == nil }
        guard !missing.isEmpty else { completion("모든 데스크탑에 배지가 이미 있습니다."); return }
        let targets = missing.compactMap { space in space.number.flatMap { SpaceSwitcher.canSwitch(to: $0) ? $0 : nil } }
        let origin = spaces.activeSpace?.number
        guard !targets.isEmpty else { completion("전환할 수 있는 데스크탑이 없습니다 (⌃숫자 단축키는 데스크탑 10까지)."); return }

        var queue = targets
        func step() {
            guard let number = queue.first else {
                if let origin { SpaceSwitcher.switchTo(number: origin) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                    let count = self?.badges.count ?? 0
                    completion("완료: 배지 \(count)개 준비됨")
                }
                return
            }
            queue.removeFirst()
            SpaceSwitcher.switchTo(number: number)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.spaces.refresh()
                if let active = self?.spaces.activeSpace { self?.ensureBadge(for: active) }
                step()
            }
        }
        step()
    }

    // MARK: - 진단

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.S"
        events.append("\(formatter.string(from: Date())) \(message)")
        if events.count > 20 { events.removeFirst(events.count - 20) }
    }

    func diagnostics() -> String {
        var lines: [String] = []
        lines.append("이름 배지: \(running ? "켜짐" : "꺼짐"), 지금 \(isVisible ? "보임" : "숨김"), 위치 \(corner.title)")
        let prepared = spaces.spaces.filter { badges[$0.uuid] != nil }.map { $0.defaultName }
        let missing = spaces.spaces.filter { !$0.isFullscreen && badges[$0.uuid] == nil }.map { $0.defaultName }
        lines.append("배지 있는 데스크탑: \(prepared.isEmpty ? "없음" : prepared.joined(separator: ", "))")
        lines.append("배지 없는 데스크탑: \(missing.isEmpty ? "없음" : missing.joined(separator: ", "))")
        if !events.isEmpty {
            lines.append("배지 기록:")
            lines.append(contentsOf: events.map { "  " + $0 })
        }
        return lines.joined(separator: "\n")
    }
}
