import AppKit

/// Mission Control이 열리면 "데스크탑 N" 라벨 자리에 사용자 지정 이름을 덮어 그린다.
///
/// 이 macOS에서는 Mission Control이 열려도 앱이 밖에서 관찰할 수 있는 상태(Dock 접근성 트리, 창 목록,
/// WindowServer 알림, 메뉴 막대)가 전혀 변하지 않는다. 그래서 화면 위쪽을 주기적으로 찍어
/// "데스크탑 N" 라벨 줄이 있는지 직접 확인하고, 있으면 그 자리에 이름표를 그리고 없으면 지운다.
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

    // 인식 상태
    private var ocrInFlight = false
    private var nextOCRAt = Date.distantPast
    private var lastImageHash = 0
    private var ocrStartedAt = Date.distantPast
    private var dismissedAt = Date.distantPast

    // 안전장치
    private var spaceObserver: NSObjectProtocol?
    private var appObserver: NSObjectProtocol?
    private var inputMonitors: [Any] = []
    private var testMode = false

    // 진단 정보
    private var tickCount = 0
    private var ocrRuns = 0
    private var skippedSameImage = 0
    private var foundCount = 0
    private var lastFoundAt: Date?
    private var lastOCRNote = "아직 실행 안 됨"
    private var lastOCRTexts: [String] = []
    private var lastLabelNote = ""
    private var events: [String] = []

    init(spaces: SpaceManager, names: NameStore) {
        self.spaces = spaces
        self.names = names
    }

    var isRunning: Bool { timer != nil }

    // MARK: - 시작/정지

    func start() {
        guard timer == nil else { return }
        if !DockAccessibility.isTrusted {
            DockAccessibility.requestTrust()
            Self.showPermissionHelp()
        }
        if !ScreenText.hasScreenCaptureAccess {
            ScreenText.requestScreenCaptureAccess()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer?.tolerance = 0.03

        // 데스크탑/앱 전환은 Mission Control이 닫혔다는 뜻이므로 바로 지운다
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
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .keyDown], handler: { [weak self] event in
            let reason = event.type == .keyDown ? "키 입력" : "클릭"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.dismiss(reason: reason) }
        })
        if let monitor { inputMonitors.append(monitor) }
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

    /// 15초 동안 화면 위쪽 가운데에 시험용 이름표를 띄운다 (패널이 보이는지 확인용).
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

        if testMode, !isShowing, let screen = NSScreen.screens.first {
            let frame = CGRect(x: screen.frame.midX - 60, y: screen.frame.maxY - 220, width: 120, height: 24)
            rebuildPanels(with: [Label(frame: frame, text: "테스트 이름표")])
            isShowing = true
            return
        }

        guard !ocrInFlight, Date() >= nextOCRAt else { return }
        startOCR()
    }

    /// 이름표가 떠 있을 때는 자주(썸네일 이동을 따라가기 위해), 아닐 때는 덜 자주 확인한다.
    /// 화면이 그대로면 인식을 건너뛰므로 실제 부담은 작다.
    private var pollInterval: TimeInterval { isShowing ? 0.3 : 0.5 }

    private func startOCR() {
        guard ScreenText.hasScreenCaptureAccess else {
            lastOCRNote = "화면 기록 권한 없음"
            nextOCRAt = Date().addingTimeInterval(3)
            return
        }
        guard let screen = NSScreen.screens.first else { return }
        ocrInFlight = true
        ocrStartedAt = Date()
        let fraction = captureFraction
        let previousHash = lastImageHash

        Task { [weak self] in
            do {
                let image = try await ScreenText.captureTopStrip(of: screen, fraction: fraction)
                let hash = ScreenText.quickHash(of: image)
                if hash == previousHash {
                    await MainActor.run { self?.finishOCR(nil, hash: hash, error: nil) }
                    return
                }
                let result = try ScreenText.recognizeDesktopLabels(in: image, screen: screen, fraction: fraction)
                await MainActor.run { self?.finishOCR(result, hash: hash, error: nil) }
            } catch {
                await MainActor.run { self?.finishOCR(nil, hash: previousHash, error: error) }
            }
        }
    }

    private func finishOCR(_ result: ScreenText.Result?, hash: Int, error: Error?) {
        ocrInFlight = false
        nextOCRAt = Date().addingTimeInterval(pollInterval)
        if ocrStartedAt < dismissedAt {
            // 제거 직전에 찍은 화면이므로 무시
            return
        }

        if let error {
            lastOCRNote = "캡처/인식 실패: \(error.localizedDescription)"
            return
        }
        guard let result else {
            // 화면이 그대로면 상태도 그대로
            skippedSameImage += 1
            return
        }
        lastImageHash = hash
        ocrRuns += 1
        lastOCRTexts = Array(result.allText.prefix(20))
        lastOCRNote = "인식 \(ocrRuns)회 (같은 화면 건너뜀 \(skippedSameImage)회), 마지막: 글자 \(result.allText.count)개, 데스크탑 라벨 \(result.labels.count)개"

        guard !result.labels.isEmpty else {
            if isShowing {
                log("라벨 줄이 사라짐 → 이름표 제거")
                hide()
            }
            return
        }

        let byNumber = Dictionary(
            spaces.spaces.compactMap { space in space.number.map { ($0, space) } },
            uniquingKeysWith: { first, _ in first }
        )
        // 라벨 줄의 세로 중심은 줄 전체의 중앙값으로 통일한다 (인식 오차로 들쭉날쭉해지는 것 방지)
        let midYs = result.labels.map(\.frame.midY).sorted()
        let rowMidY = midYs[midYs.count / 2]
        let labelFont = NSFont.systemFont(ofSize: 13)

        var labels: [Label] = []
        for found in result.labels {
            guard let space = byNumber[found.number], let custom = names.customName(for: space) else { continue }
            // 인식된 영역은 실제 글자보다 좁을 때가 있으므로, 원래 라벨 폭을 글꼴로 직접 계산해 넉넉히 덮는다
            let originalWidth = (found.text as NSString).size(withAttributes: [.font: labelFont]).width
            let width = max(found.frame.width, originalWidth) + 32
            let height: CGFloat = 24
            let frame = CGRect(x: found.frame.midX - width / 2, y: rowMidY - height / 2, width: width, height: height)
            labels.append(Label(frame: frame, text: custom))
        }
        lastLabelNote = labels.isEmpty
            ? "없음 (인식한 라벨 \(result.labels.map(\.text).joined(separator: ", ")) 중 이름이 지정된 것이 없음)"
            : labels.map { "\($0.text) @ (\(Int($0.frame.minX)), \(Int($0.frame.minY)))" }.joined(separator: ", ")

        if !isShowing {
            foundCount += 1
            lastFoundAt = Date()
            log("라벨 줄 발견 (\(result.labels.count)개) → 이름표 \(labels.count)개 표시")
        }
        guard !labels.isEmpty else {
            // 라벨 줄은 있는데 이름 지정된 것만 못 읽은 경우(애니메이션 중 등)는 기존 이름표를 유지한다
            return
        }
        // 이미 표시 중이면 개수가 바뀌거나 8pt 넘게 움직였을 때만 다시 그린다 (미세한 흔들림 방지)
        if !isShowing || Self.changedNoticeably(labels, currentLabels) {
            rebuildPanels(with: labels)
            currentLabels = labels
        }
        isShowing = true
    }

    private static func changedNoticeably(_ new: [Label], _ old: [Label]) -> Bool {
        guard new.count == old.count else { return true }
        for (a, b) in zip(new, old) {
            if a.text != b.text { return true }
            if abs(a.frame.midX - b.frame.midX) > 3 || abs(a.frame.midY - b.frame.midY) > 3 { return true }
        }
        return false
    }

    /// 이름표를 지우고, 닫히는 애니메이션 동안 다시 그리지 않도록 다음 확인을 잠깐 미룬다.
    private func dismiss(reason: String) {
        guard isShowing else { return }
        log("\(reason)으로 이름표 제거")
        hide()
        dismissedAt = Date()
        nextOCRAt = Date().addingTimeInterval(0.8)
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.S"
        events.append("\(formatter.string(from: Date())) \(message)")
        if events.count > 30 { events.removeFirst(events.count - 30) }
    }

    // MARK: - 진단

    func diagnostics() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        var lines: [String] = []
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("접근성 권한: \(DockAccessibility.isTrusted ? "허용됨" : "없음")")
        lines.append("화면 기록 권한: \(ScreenText.hasScreenCaptureAccess ? "허용됨" : "없음 (시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음에서 DesktopNamer 켜기)")")
        lines.append("앱 위치: \(DockAccessibility.signingInfo())")
        lines.append("오버레이 실행 중: \(isRunning ? "예" : "아니오") (검사 \(tickCount)회)")
        lines.append("글자 인식: \(lastOCRNote)")
        if !lastOCRTexts.isEmpty {
            lines.append("인식된 글자: " + lastOCRTexts.joined(separator: " | "))
        }
        lines.append("라벨 줄 발견: \(foundCount)회, 마지막 \(lastFoundAt.map { formatter.string(from: $0) } ?? "없음")")
        lines.append("그린 이름표: \(lastLabelNote.isEmpty ? "없음" : lastLabelNote)")
        lines.append("이름표 표시 중: \(isShowing ? "예" : "아니오")")
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
        pill.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1.0).cgColor
        pill.layer?.cornerRadius = height / 2

        field.frame = CGRect(x: padding, y: (height - field.frame.height) / 2, width: width - padding * 2, height: field.frame.height)
        pill.addSubview(field)
        return pill
    }
}
