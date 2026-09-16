import AppKit

/// Mission Control이 열리면 "데스크탑 N" 라벨 자리에 사용자 지정 이름을 덮어 그린다.
///
/// 이 macOS에서는 Mission Control이 열려도 앱이 밖에서 관찰할 수 있는 상태가 전혀 변하지 않는다.
/// 그래서 화면 위쪽 띠를 실시간 스트림으로 받아, 프레임이 바뀔 때마다 "데스크탑 N" 라벨 줄을 찾고
/// 있으면 그 자리에 이름표를 그리고 없으면 지운다. 이름표가 떠 있는 동안은 라벨 줄 높이의
/// 얇은 띠만 인식해서 썸네일 이동을 빠르게 따라간다.
final class MissionControlOverlay {
    private struct Label: Equatable {
        let frame: CGRect
        let text: String
    }

    private let spaces: SpaceManager
    private let names: NameStore

    private let stream = ScreenStream()
    private var strip: ScreenText.Strip?
    private var retryTimer: Timer?
    private var running = false

    private var panels: [NSPanel] = []
    private var isShowing = false
    private var currentLabels: [Label] = []
    /// 마지막으로 찾은 라벨 줄의 세로 중심 (AppKit). 띠 인식 범위 계산에 쓴다.
    private var rowMidY: CGFloat?

    /// 캡처할 화면 위쪽 비율
    private let captureFraction: CGFloat = 0.3
    /// 이름표가 떠 있을 때 인식하는 띠의 절반 높이(pt)
    private let bandHalfHeight: CGFloat = 40

    // 인식 상태 (스트림 큐에서만 접근)
    private var processing = false
    private var lastProcessedAt = Date.distantPast
    private var showingForQueue = false
    private var rowMidYForQueue: CGFloat?

    private var dismissedAt = Date.distantPast

    // 안전장치
    private var spaceObserver: NSObjectProtocol?
    private var appObserver: NSObjectProtocol?
    private var inputMonitors: [Any] = []

    // 진단 정보
    private var frameCount = 0
    private var ocrRuns = 0
    private var foundCount = 0
    private var lastFoundAt: Date?
    private var lastOCRNote = "아직 실행 안 됨"
    private var lastOCRTexts: [String] = []
    private var lastLabelNote = ""
    private var lastOCRDuration: TimeInterval = 0
    private var events: [String] = []

    init(spaces: SpaceManager, names: NameStore) {
        self.spaces = spaces
        self.names = names
    }

    var isRunning: Bool { running }

    // MARK: - 시작/정지

    func start() {
        guard !running else { return }
        running = true
        if !DockAccessibility.isTrusted {
            DockAccessibility.requestTrust()
            Self.showPermissionHelp()
        }
        if !ScreenText.hasScreenCaptureAccess {
            ScreenText.requestScreenCaptureAccess()
        }

        stream.onFrame = { [weak self] buffer in self?.handleFrame(buffer) }
        stream.onStop = { [weak self] error in
            DispatchQueue.main.async {
                self?.log("스트림 중단: \(error.localizedDescription)")
                self?.scheduleStreamStart(after: 3)
            }
        }
        startStream()

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
        running = false
        retryTimer?.invalidate()
        retryTimer = nil
        stream.stop()
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

    private func startStream() {
        guard running, !stream.isRunning else { return }
        guard ScreenText.hasScreenCaptureAccess else {
            log("화면 기록 권한 없음 → 5초 후 재시도")
            scheduleStreamStart(after: 5)
            return
        }
        guard let screen = NSScreen.screens.first else { return }
        let strip = ScreenText.Strip(screen: screen, fraction: captureFraction)
        self.strip = strip
        Task { [weak self] in
            do {
                try await self?.stream.start(strip: strip)
                await MainActor.run { self?.log("화면 스트림 시작 (\(Int(strip.pixelSize.width))×\(Int(strip.pixelSize.height))px)") }
            } catch {
                await MainActor.run {
                    self?.log("화면 스트림 시작 실패: \(error.localizedDescription)")
                    self?.scheduleStreamStart(after: 5)
                }
            }
        }
    }

    private func scheduleStreamStart(after seconds: TimeInterval) {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.startStream()
        }
    }

    /// 15초 동안 화면 위쪽 가운데에 시험용 이름표를 띄운다 (패널이 보이는지 확인용).
    func runVisibilityTest() {
        guard let screen = NSScreen.screens.first else { return }
        let frame = CGRect(x: screen.frame.midX - 60, y: screen.frame.maxY - 220, width: 120, height: 24)
        rebuildPanels(with: [Label(frame: frame, text: "테스트 이름표")])
        isShowing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.hide() }
    }

    // MARK: - 프레임 처리 (스트림 큐)

    private func handleFrame(_ buffer: CVPixelBuffer) {
        guard let strip else { return }
        frameCount += 1
        if processing { return }
        // 이름표가 없을 때는 초당 4회까지만 인식한다 (일반 화면 변화에 CPU를 쓰지 않도록)
        let minInterval: TimeInterval = showingForQueue ? 0 : 0.15
        guard Date().timeIntervalSince(lastProcessedAt) >= minInterval else { return }
        processing = true
        let started = Date()

        // 이름표가 떠 있으면 라벨 줄 주변의 얇은 띠만 인식해 속도를 높인다
        let region: CGRect
        if showingForQueue, let midY = rowMidYForQueue {
            region = strip.regionOfInterest(centerY: midY, halfHeight: bandHalfHeight)
        } else {
            region = ScreenText.fullRegion
        }

        let result = try? ScreenText.recognizeDesktopLabels(in: buffer, strip: strip, regionOfInterest: region)
        let duration = Date().timeIntervalSince(started)
        lastProcessedAt = Date()
        processing = false

        DispatchQueue.main.async { [weak self] in
            self?.finishOCR(result, startedAt: started, duration: duration)
        }
    }

    // MARK: - 결과 반영 (메인 스레드)

    private func finishOCR(_ result: ScreenText.Result?, startedAt: Date, duration: TimeInterval) {
        lastOCRDuration = duration
        guard startedAt >= dismissedAt else { return } // 제거 직전에 찍은 화면은 무시
        guard let result else {
            lastOCRNote = "인식 실패"
            return
        }
        ocrRuns += 1
        lastOCRTexts = Array(result.allText.prefix(20))
        lastOCRNote = "인식 \(ocrRuns)회 (프레임 \(frameCount)개), 마지막: \(Int(duration * 1000))ms, 글자 \(result.allText.count)개, 데스크탑 라벨 \(result.labels.count)개"

        guard !result.labels.isEmpty else {
            if isShowing {
                // 원래 라벨 대신 우리 이름표 글자가 읽혔다면 아직 열려 있는 것 (캡처 제외가 안 된 경우 대비)
                let ownTexts = Set(currentLabels.map(\.text))
                let seenOwn = result.allText.filter { ownTexts.contains($0) }.count
                if seenOwn >= min(2, ownTexts.count) { return }
                log("라벨 줄이 사라짐 → 이름표 제거")
                hide()
            }
            return
        }

        let byNumber = Dictionary(
            spaces.spaces.compactMap { space in space.number.map { ($0, space) } },
            uniquingKeysWith: { first, _ in first }
        )
        let midYs = result.labels.map(\.frame.midY).sorted()
        let midY = midYs[midYs.count / 2]
        let labelFont = NSFont.systemFont(ofSize: 13)

        var labels: [Label] = []
        for found in result.labels {
            guard let space = byNumber[found.number], let custom = names.customName(for: space) else { continue }
            // 인식된 영역은 실제 글자보다 좁을 때가 있으므로, 원래 라벨 폭을 글꼴로 직접 계산해 넉넉히 덮는다
            let originalWidth = (found.text as NSString).size(withAttributes: [.font: labelFont]).width
            let width = max(found.frame.width, originalWidth) + 32
            let height: CGFloat = 24
            labels.append(Label(
                frame: CGRect(x: found.frame.midX - width / 2, y: midY - height / 2, width: width, height: height),
                text: custom
            ))
        }
        lastLabelNote = labels.isEmpty
            ? "없음 (인식한 라벨 \(result.labels.map(\.text).joined(separator: ", ")) 중 이름이 지정된 것이 없음)"
            : labels.map { "\($0.text) @ (\(Int($0.frame.minX)), \(Int($0.frame.minY)))" }.joined(separator: ", ")

        // 라벨 줄은 있는데 이름 지정된 것만 못 읽은 경우(애니메이션 중 등)는 기존 이름표를 유지한다
        guard !labels.isEmpty else { return }

        rowMidY = midY
        if !isShowing {
            foundCount += 1
            lastFoundAt = Date()
            log("라벨 줄 발견 (\(result.labels.count)개) → 이름표 \(labels.count)개 표시")
            rebuildPanels(with: labels)
        } else if labels.map(\.text) == currentLabels.map(\.text) {
            movePanels(to: labels)
        } else {
            rebuildPanels(with: labels)
        }
        currentLabels = labels
        setShowing(true)
    }

    private func setShowing(_ showing: Bool) {
        isShowing = showing
        let midY = rowMidY
        // 프레임 처리 큐에서 읽는 값이므로 그 큐에서 바꾼다
        stream.perform { [weak self] in
            self?.showingForQueue = showing
            self?.rowMidYForQueue = midY
        }
    }

    /// 이름표를 지우고, 닫히는 애니메이션 동안 잠깐 다시 그리지 않는다.
    private func dismiss(reason: String) {
        guard isShowing else { return }
        log("\(reason)으로 이름표 제거")
        hide()
        dismissedAt = Date().addingTimeInterval(0.5)
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
        lines.append("오버레이 실행 중: \(running ? "예" : "아니오"), 화면 스트림: \(stream.isRunning ? "동작" : "정지")")
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
        setShowing(false)
    }

    /// 이름표 글자가 같으면 패널을 새로 만들지 않고 자리만 옮긴다 (깜빡임 없이 따라가기)
    private func movePanels(to labels: [Label]) {
        guard panels.count == labels.count else {
            rebuildPanels(with: labels)
            return
        }
        for (panel, label) in zip(panels, labels) {
            let size = panel.frame.size
            let origin = CGPoint(x: label.frame.midX - size.width / 2, y: label.frame.midY - size.height / 2)
            if abs(panel.frame.origin.x - origin.x) > 0.5 || abs(panel.frame.origin.y - origin.y) > 0.5 {
                panel.setFrameOrigin(origin)
            }
        }
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
            // 화면 캡처에서 제외: 우리 이름표가 원래 라벨을 가려 "라벨이 사라졌다"고 착각하지 않도록
            panel.sharingType = .none
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            pill.frame.origin = .zero
            panel.contentView = pill
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    /// 어두운 알약 배경 위에 흰 글씨. 원래 "데스크탑 N" 글자 위를 완전히 덮는다.
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
