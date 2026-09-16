import AppKit

/// Mission Control이 열리면 "데스크탑 N" 라벨 자리에 사용자 지정 이름을 덮어 그린다.
/// 라벨 위치는 화면을 찍어 글자를 인식해서 찾는다 (이 macOS에서는 Dock 접근성 트리가 비어 있음).
final class MissionControlOverlay {
    private struct Label: Equatable {
        let frame: CGRect
        let text: String
    }

    private let spaces: SpaceManager
    private let names: NameStore

    private var timer: Timer?
    private var panels: [NSPanel] = []
    private var isShowing = false
    private var currentLabels: [Label] = []

    /// 캡처할 화면 위쪽 비율
    private let captureFraction: CGFloat = 0.3

    // Mission Control 열림 상태와 인식 시도
    private var wasOpen = false
    private var openedAt: Date?
    private var ocrAttempts = 0
    private var ocrInFlight = false
    private var nextOCRAt = Date.distantPast
    private let maxOCRAttempts = 6

    // 진단 정보
    private var tickCount = 0
    private var openCount = 0
    private var lastOpenAt: Date?
    private var lastOCRNote = "아직 실행 안 됨"
    private var lastOCRTexts: [String] = []
    private var lastLabelNote = ""
    private var axNote = ""
    private var testMode = false
    private var events: [String] = []
    /// 데스크탑 전환으로 지운 뒤, 닫힘이 한 번 감지될 때까지 다시 그리지 않는다
    private var suppressUntilClosed = false
    private var spaceObserver: NSObjectProtocol?
    private var appObserver: NSObjectProtocol?
    private var inputMonitors: [Any] = []

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
        if !ScreenText.hasScreenCaptureAccess {
            ScreenText.requestScreenCaptureAccess()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer?.tolerance = 0.05

        // 데스크탑이 바뀌면 Mission Control은 닫힌 것이므로 무조건 지운다 (안전장치)
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.dismiss(reason: "데스크탑 전환")
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.dismiss(reason: "앱 전환")
        }
        // Mission Control 안에서의 클릭이나 키 입력은 거의 항상 닫는 동작이다
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            let reason = event.type == .keyDown ? "키 입력" : "클릭"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.dismiss(reason: reason) }
        } {
            inputMonitors.append(monitor)
        }
    }

    /// 이름표를 지우고, 닫힘이 감지될 때까지 다시 그리지 않는다.
    private func dismiss(reason: String) {
        guard isShowing else { return }
        log("\(reason)으로 이름표 제거")
        hide()
        suppressUntilClosed = true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
        if let appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appObserver)
            self.appObserver = nil
        }
        inputMonitors.forEach { NSEvent.removeMonitor($0) }
        inputMonitors.removeAll()
        hide()
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.S"
        events.append("\(formatter.string(from: Date())) \(message)")
        if events.count > 20 { events.removeFirst(events.count - 20) }
    }

    /// 15초 동안 Mission Control이 열리면 화면 위쪽 가운데에 시험용 이름표를 띄운다 (패널이 보이는지 확인용).
    func runVisibilityTest() {
        testMode = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.testMode = false
            self?.hide()
        }
    }

    // MARK: - 주기 검사

    private func tick() {
        tickCount += 1
        let open = DockAccessibility.isMissionControlLikelyOpen()

        if !open {
            if wasOpen {
                log("닫힘 감지 (Dock 창: \(Self.describeDockWindows()))")
                hide()
                ocrAttempts = 0
                ocrInFlight = false
            }
            wasOpen = false
            suppressUntilClosed = false
            return
        }

        if suppressUntilClosed { return }

        if !wasOpen {
            wasOpen = true
            openedAt = Date()
            lastOpenAt = openedAt
            openCount += 1
            log("열림 감지 (Dock 창: \(Self.describeDockWindows()))")
            ocrAttempts = 0
            nextOCRAt = Date().addingTimeInterval(0.35) // 열리는 애니메이션이 끝날 때까지 대기
            axNote = DockAccessibility.scan().note
        }

        if testMode, !isShowing, let screen = NSScreen.screens.first {
            let frame = CGRect(x: screen.frame.midX - 60, y: screen.frame.maxY - 220, width: 120, height: 24)
            rebuildPanels(with: [Label(frame: frame, text: "테스트 이름표")])
            isShowing = true
            return
        }

        guard !isShowing, !ocrInFlight, ocrAttempts < maxOCRAttempts, Date() >= nextOCRAt else { return }
        startOCR()
    }

    private func startOCR() {
        guard ScreenText.hasScreenCaptureAccess else {
            lastOCRNote = "화면 기록 권한 없음"
            ocrAttempts = maxOCRAttempts
            return
        }
        guard let screen = NSScreen.screens.first else { return }
        ocrInFlight = true
        ocrAttempts += 1
        let fraction = captureFraction

        Task { [weak self] in
            do {
                let image = try await ScreenText.captureTopStrip(of: screen, fraction: fraction)
                let result = try ScreenText.recognizeDesktopLabels(in: image, screen: screen, fraction: fraction)
                await MainActor.run { self?.finishOCR(result, error: nil) }
            } catch {
                await MainActor.run { self?.finishOCR(nil, error: error) }
            }
        }
    }

    private func finishOCR(_ result: ScreenText.Result?, error: Error?) {
        ocrInFlight = false
        nextOCRAt = Date().addingTimeInterval(0.3)

        guard let result else {
            lastOCRNote = "캡처/인식 실패: \(error?.localizedDescription ?? "알 수 없음")"
            return
        }
        lastOCRTexts = Array(result.allText.prefix(20))
        lastOCRNote = "시도 \(ocrAttempts)회, 글자 \(result.allText.count)개, 데스크탑 라벨 \(result.labels.count)개"
        guard !result.labels.isEmpty, wasOpen else { return }

        let byNumber = Dictionary(
            spaces.spaces.compactMap { space in space.number.map { ($0, space) } },
            uniquingKeysWith: { first, _ in first }
        )
        var labels: [Label] = []
        for found in result.labels {
            guard let space = byNumber[found.number], let custom = names.customName(for: space) else { continue }
            // 원래 글자를 완전히 덮도록 조금 넓게
            let frame = found.frame.insetBy(dx: -10, dy: -5)
            labels.append(Label(frame: frame, text: custom))
        }
        lastLabelNote = labels.isEmpty
            ? "없음 (인식한 라벨 \(result.labels.map(\.text).joined(separator: ", ")) 중 이름이 지정된 것이 없음)"
            : labels.map { "\($0.text) @ (\(Int($0.frame.minX)), \(Int($0.frame.minY)))" }.joined(separator: ", ")

        // 라벨은 찾았지만 이름이 없는 경우도 "완료"로 보고 더 시도하지 않는다.
        ocrAttempts = maxOCRAttempts
        guard !labels.isEmpty else { return }
        rebuildPanels(with: labels)
        currentLabels = labels
        isShowing = true
        log("이름표 \(labels.count)개 표시")
    }

    private static func describeDockWindows() -> String {
        let windows = DockAccessibility.dockWindows()
        guard !windows.isEmpty else { return "없음" }
        return windows.map { "\($0.name.isEmpty ? "(이름 없음)" : $0.name) \(Int($0.frame.width))×\(Int($0.frame.height)) layer \($0.layer)" }
            .joined(separator: ", ")
    }

    // MARK: - 진단

    func diagnostics() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        var lines: [String] = []
        lines.append("접근성 권한: \(DockAccessibility.isTrusted ? "허용됨" : "없음")")
        lines.append("화면 기록 권한: \(ScreenText.hasScreenCaptureAccess ? "허용됨" : "없음 (시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음에서 DesktopNamer 켜기)")")
        lines.append("앱 위치: \(DockAccessibility.signingInfo())")
        lines.append("오버레이 실행 중: \(isRunning ? "예" : "아니오") (검사 \(tickCount)회)")
        lines.append("Mission Control 열림 감지: \(openCount)회, 마지막 \(lastOpenAt.map { formatter.string(from: $0) } ?? "없음")")
        lines.append("글자 인식: \(lastOCRNote)")
        if !lastOCRTexts.isEmpty {
            lines.append("인식된 글자: " + lastOCRTexts.joined(separator: " | "))
        }
        lines.append("그린 이름표: \(lastLabelNote.isEmpty ? "없음" : lastLabelNote)")
        lines.append("지금 Dock 창: \(Self.describeDockWindows())")
        lines.append("지금 열림 판정: \(DockAccessibility.isMissionControlLikelyOpen() ? "열림" : "닫힘"), 이름표 표시 중: \(isShowing ? "예" : "아니오")")
        if !events.isEmpty {
            lines.append("기록:")
            lines.append(contentsOf: events.map { "  " + $0 })
        }
        lines.append("이름 저장 목록: \(names.names.isEmpty ? "없음" : names.names.values.joined(separator: ", "))")
        lines.append("공간 목록: " + spaces.spaces.map { $0.number.map { String($0) } ?? "전체화면" }.joined(separator: ", "))
        lines.append("화면: " + NSScreen.screens.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) @ (\(Int($0.frame.minX)), \(Int($0.frame.minY))) 배율 \($0.backingScaleFactor)" }.joined(separator: " / "))
        return lines.joined(separator: "\n")
    }

    static func showPermissionHelp() {
        let alert = NSAlert()
        alert.messageText = "손쉬운 사용 권한이 필요합니다"
        alert.informativeText = "시스템 설정 > 개인정보 보호 및 보안에서 DesktopNamer를 켜 주세요. 이미 켜져 있는데도 이 창이 뜬다면 메뉴의 '접근성 권한 초기화 후 다시 요청'을 눌러 주세요."
        alert.addButton(withTitle: "확인")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - 패널 그리기

    private func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        currentLabels = []
        isShowing = false
    }

    private func rebuildPanels(with labels: [Label]) {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()

        // 이름표마다 딱 그 크기의 작은 패널을 만든다. 화면 전체 패널은 Mission Control 썸네일을 가린다.
        for label in labels {
            let pill = Self.makeLabel(text: label.text, in: CGRect(origin: .zero, size: label.frame.size))
            let origin = CGPoint(
                x: label.frame.midX - pill.frame.width / 2,
                y: label.frame.midY - pill.frame.height / 2
            )
            let panel = NSPanel(
                contentRect: CGRect(origin: origin, size: pill.frame.size),
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
            pill.frame.origin = .zero
            panel.contentView = pill
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
        let width = max(field.frame.width + padding * 2, area.width)
        let height = max(area.height, 22)
        let pill = NSView(frame: CGRect(
            x: area.midX - width / 2,
            y: area.midY - height / 2,
            width: width,
            height: height
        ))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.85).cgColor
        pill.layer?.cornerRadius = height / 2

        field.frame = CGRect(x: padding, y: (height - field.frame.height) / 2, width: width - padding * 2, height: field.frame.height)
        pill.addSubview(field)
        return pill
    }
}
