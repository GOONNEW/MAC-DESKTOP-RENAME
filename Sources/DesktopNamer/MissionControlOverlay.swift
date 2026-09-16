import AppKit
import ScreenCaptureKit

/// Mission Control이 열리면 "데스크탑 N" 라벨 자리에 사용자 지정 이름을 덮어 그린다.
///
/// 이 macOS에서는 Mission Control이 열려도 앱이 밖에서 관찰할 수 있는 상태가 전혀 변하지 않는다.
/// 그래서 화면 위쪽 띠를 실시간 스트림으로 받아, 프레임이 바뀔 때마다 "데스크탑 N" 라벨 줄을 찾고
/// 있으면 그 자리에 이름표를 그리고 없으면 지운다.
///
/// 화면 감시는 기본적으로 Mission Control을 여는 동작(키, 제스처)이 감지될 때만 잠깐 켠다.
/// 항상 켜 두면 메뉴 막대에 화면 기록 표시가 계속 뜨기 때문이다.
final class MissionControlOverlay {
    private struct Label: Equatable {
        let number: Int
        let frame: CGRect
        let text: String
    }

    private struct Tracked {
        var label: Label
        var lastSeen: Date
    }

    private let spaces: SpaceManager
    private let names: NameStore

    private let stream = ScreenStream()
    private let trigger = MissionControlTrigger()
    private let trackpad = TrackpadMonitor()
    private var trackpadWorks = false
    private var strip: ScreenText.Strip?
    private var running = false
    private var housekeeping: Timer?

    /// true면 화면 감시를 항상 켠다 (가장 빠르지만 화면 기록 표시가 계속 뜬다)
    var alwaysWatch = false {
        didSet { if running { applyWatchMode() } }
    }
    /// 감시를 끄기로 예정된 시각 (동작 감지 후 몇 초, 이름표가 보이는 동안은 계속 연장)
    private var watchUntil = Date.distantPast
    private var streamStarting = false

    private var panels: [NSPanel] = []
    private var panelLabels: [Label] = []
    private var isShowing = false
    private var tracked: [Int: Tracked] = [:]
    private var rowMidY: CGFloat?
    /// 우리 앱이 캡처 제외 목록에 들어가도록 항상 떠 있는 1×1 창
    private var anchorWindow: NSPanel?

    /// 캡처할 화면 위쪽 비율
    private let captureFraction: CGFloat = 0.3
    /// 이름표가 떠 있을 때 인식하는 띠의 절반 높이(pt)
    private let bandHalfHeight: CGFloat = 60
    /// 캡처 배율 (레티나 2.0 대신 1.5로 낮춰 인식 속도를 높인다)
    private let captureScale: CGFloat = 1.5
    /// 인식이 놓친 이름표를 유지하는 시간
    private let keepMissingFor: TimeInterval = 0.6

    // 인식 상태 (스트림 큐에서만 접근)
    private var processing = false
    private var lastProcessedAt = Date.distantPast
    private var showingForQueue = false
    private var rowMidYForQueue: CGFloat?
    /// 띠 인식에서 라벨을 놓쳤을 때 다음 프레임은 전체 범위로 확인한다
    private var verifyFullForQueue = false

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
    private var lastTriggerNote = "없음"
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
        makeAnchorWindow()

        stream.onFrame = { [weak self] buffer in self?.handleFrame(buffer) }
        stream.onStop = { [weak self] error in
            DispatchQueue.main.async {
                self?.log("스트림 중단: \(error.localizedDescription)")
                self?.streamStarting = false
            }
        }

        // 트랙패드 손가락 개수 (세 손가락 이상일 때만 감시 시작)
        TrackpadMonitor.onTouchCountChanged = { [weak self] count in
            if count >= 3 { self?.wake(reason: "트랙패드 \(count)손가락") }
        }
        trackpadWorks = trackpad.startMonitoring()
        if !trackpadWorks { log("트랙패드 감시 실패: \(trackpad.note) → 제스처 이벤트로 대체") }

        // 키보드 (트랙패드 감시가 안 되면 제스처 이벤트도 포함)
        trigger.onTrigger = { [weak self] reason in self?.wake(reason: reason) }
        if !trigger.start(includeGestures: !trackpadWorks) {
            log("동작 감지 시작 실패: \(trigger.lastNote)")
        }

        housekeeping = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.housekeep()
        }
        applyWatchMode()

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
        housekeeping?.invalidate()
        housekeeping = nil
        trigger.stop()
        trackpad.stopMonitoring()
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
        anchorWindow?.orderOut(nil)
        anchorWindow = nil
    }

    /// 화면 캡처의 제외 목록은 "창을 가진 앱" 단위로 만들어지므로, 우리 앱이 늘 창 하나를 갖게 한다.
    private func makeAnchorWindow() {
        guard anchorWindow == nil, let screen = NSScreen.screens.first else { return }
        let panel = NSPanel(
            contentRect: CGRect(x: screen.frame.minX, y: screen.frame.minY, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.01)
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.orderFrontRegardless()
        anchorWindow = panel
    }

    // MARK: - 감시 모드

    private func applyWatchMode() {
        if alwaysWatch {
            startStream()
        } else if !isShowing, Date() > watchUntil {
            stopStreamIfIdle()
        }
        log(alwaysWatch ? "항상 감시 모드" : "동작 감지 시 감시 모드")
    }

    /// Mission Control을 여는 동작이 감지되면 몇 초간 화면 감시를 켠다.
    private func wake(reason: String) {
        watchUntil = Date().addingTimeInterval(8)
        if !stream.isRunning && !streamStarting {
            lastTriggerNote = "\(reason) (\(Self.timeString(Date())))"
            log("동작 감지: \(reason) → 감시 시작")
            startStream()
        }
    }

    private func housekeep() {
        // 오래 안 보인 이름표 정리
        if isShowing {
            let now = Date()
            let stale = tracked.filter { now.timeIntervalSince($0.value.lastSeen) > keepMissingFor * 3 }
            if !stale.isEmpty {
                stale.keys.forEach { tracked.removeValue(forKey: $0) }
                render()
            }
        }
        // 감시 끄기
        if !alwaysWatch, stream.isRunning, !isShowing, Date() > watchUntil {
            stopStreamIfIdle()
        }
    }

    private func stopStreamIfIdle() {
        guard stream.isRunning else { return }
        stream.stop()
        log("감시 종료")
    }

    private func startStream() {
        guard running, !stream.isRunning, !streamStarting else { return }
        guard ScreenText.hasScreenCaptureAccess else {
            log("화면 기록 권한 없음")
            return
        }
        guard let screen = NSScreen.screens.first else { return }
        let strip = ScreenText.Strip(screen: screen, fraction: captureFraction, scale: captureScale)
        self.strip = strip
        streamStarting = true
        Task { [weak self] in
            do {
                try await self?.stream.start(strip: strip)
                await MainActor.run {
                    self?.streamStarting = false
                    self?.log("화면 스트림 시작")
                }
            } catch {
                await MainActor.run {
                    self?.streamStarting = false
                    self?.log("화면 스트림 시작 실패: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 15초 동안 화면 위쪽 가운데에 시험용 이름표를 띄운다 (패널이 보이는지 확인용).
    func runVisibilityTest() {
        guard let screen = NSScreen.screens.first else { return }
        let frame = CGRect(x: screen.frame.midX - 60, y: screen.frame.maxY - 220, width: 120, height: 24)
        rebuildPanels(with: [Label(number: 0, frame: frame, text: "테스트 이름표")])
        isShowing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.hide() }
    }

    // MARK: - 프레임 처리 (스트림 큐)

    private func handleFrame(_ buffer: CVPixelBuffer) {
        guard let strip else { return }
        frameCount += 1
        if processing { return }
        // 이름표가 없을 때는 초당 20회까지 인식한다 (감시는 잠깐만 켜지므로 부담이 작다)
        let minInterval: TimeInterval = showingForQueue ? 0 : 0.05
        guard Date().timeIntervalSince(lastProcessedAt) >= minInterval else { return }
        processing = true
        let started = Date()

        // 이름표가 떠 있으면 라벨 줄 주변의 얇은 띠만 인식해 속도를 높인다.
        // 단, 직전 띠 인식에서 라벨을 놓쳤으면 이번엔 전체를 본다 (라벨이 위아래로 이동했을 수 있음).
        let useBand = showingForQueue && !verifyFullForQueue
        let region: CGRect
        if useBand, let midY = rowMidYForQueue {
            region = strip.regionOfInterest(centerY: midY, halfHeight: bandHalfHeight)
        } else {
            region = ScreenText.fullRegion
        }

        let result = try? ScreenText.recognizeDesktopLabels(in: buffer, strip: strip, regionOfInterest: region)
        let duration = Date().timeIntervalSince(started)
        lastProcessedAt = Date()
        processing = false

        if useBand, let result, result.labels.isEmpty {
            // 띠에서 놓침 → 아직 지우지 않고 다음 프레임을 전체로 확인
            verifyFullForQueue = true
            return
        }
        if let result, !result.labels.isEmpty { verifyFullForQueue = false }

        DispatchQueue.main.async { [weak self] in
            self?.finishOCR(result, startedAt: started, duration: duration)
        }
    }

    // MARK: - 결과 반영 (메인 스레드)

    private func finishOCR(_ result: ScreenText.Result?, startedAt: Date, duration: TimeInterval) {
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
                // 우리 이름표 자리에서 글자가 읽혔다면(이름표가 캡처에 찍힌 것) 아직 열려 있는 것
                let ownFrames = panelLabels.map(\.frame)
                let onOwn = result.allFrames.filter { frame in ownFrames.contains { $0.intersects(frame) } }.count
                if onOwn >= 1 {
                    watchUntil = Date().addingTimeInterval(3)
                    return
                }
                log("라벨 줄이 사라짐 → 이름표 제거")
                hide()
            }
            return
        }

        // 이름표가 보이는 동안은 감시를 계속 연장한다
        watchUntil = Date().addingTimeInterval(3)

        let byNumber = Dictionary(
            spaces.spaces.compactMap { space in space.number.map { ($0, space) } },
            uniquingKeysWith: { first, _ in first }
        )
        let sorted = result.labels.sorted { $0.frame.midX < $1.frame.midX }
        let midYs = sorted.map(\.frame.midY).sorted()
        let midY = midYs[midYs.count / 2]
        let labelFont = NSFont.systemFont(ofSize: 13)
        let nameFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let now = Date()

        // 줄 높이가 크게 바뀌면(접힌 줄 ↔ 펼친 썸네일) 이전 이름표는 모두 버린다
        if let previous = rowMidY, abs(previous - midY) > 20 {
            tracked.removeAll()
        }
        rowMidY = midY

        var matched = 0
        for (index, found) in sorted.enumerated() {
            guard let space = byNumber[found.number], let custom = names.customName(for: space) else { continue }
            matched += 1

            // 옆 라벨과의 간격 안에 들어가도록 폭을 제한한다 (접힌 줄에서는 라벨이 촘촘하다)
            var maxWidth = CGFloat.greatestFiniteMagnitude
            if index > 0 { maxWidth = min(maxWidth, found.frame.midX - sorted[index - 1].frame.midX - 6) }
            if index < sorted.count - 1 { maxWidth = min(maxWidth, sorted[index + 1].frame.midX - found.frame.midX - 6) }

            let originalWidth = (found.text as NSString).size(withAttributes: [.font: labelFont]).width
            let nameWidth = (custom as NSString).size(withAttributes: [.font: nameFont]).width
            let desired = max(found.frame.width, originalWidth, nameWidth) + 28
            let width = max(40, min(desired, maxWidth))
            let height = max(20, min(28, found.frame.height + 8))
            let frame = CGRect(x: found.frame.midX - width / 2, y: midY - height / 2, width: width, height: height)
            tracked[found.number] = Tracked(label: Label(number: found.number, frame: frame, text: custom), lastSeen: now)
        }

        // 이번에 못 읽은 이름표는 잠깐 유지한다 (인식이 한 번 놓쳐도 깜빡이지 않도록)
        let expired = tracked.filter { now.timeIntervalSince($0.value.lastSeen) > keepMissingFor }
        expired.keys.forEach { tracked.removeValue(forKey: $0) }

        lastLabelNote = tracked.isEmpty
            ? "없음 (인식한 라벨 \(sorted.map(\.text).joined(separator: ", ")) 중 이름이 지정된 것이 없음)"
            : tracked.values.sorted { $0.label.frame.minX < $1.label.frame.minX }
                .map { "\($0.label.text) @ (\(Int($0.label.frame.minX)), \(Int($0.label.frame.minY))) 폭 \(Int($0.label.frame.width))" }
                .joined(separator: ", ")

        // 라벨 줄은 있는데 이름 지정된 것을 하나도 못 읽었고 유지할 것도 없으면 그대로 둔다
        guard !tracked.isEmpty else { return }

        if !isShowing {
            foundCount += 1
            lastFoundAt = now
            log("라벨 줄 발견 (\(sorted.count)개, 이름 \(matched)개) → 표시")
        }
        render()
    }

    /// tracked 내용을 화면에 반영한다. 글자가 같으면 자리만 옮기고, 다르면 새로 만든다.
    private func render() {
        let labels = tracked.values.map(\.label).sorted { $0.frame.minX < $1.frame.minX }
        guard !labels.isEmpty else {
            if isShowing { hide() }
            return
        }
        let sameShape = labels.count == panelLabels.count
            && zip(labels, panelLabels).allSatisfy { $0.text == $1.text && abs($0.frame.width - $1.frame.width) < 1 && abs($0.frame.height - $1.frame.height) < 1 }
        if isShowing, sameShape {
            movePanels(to: labels)
        } else {
            rebuildPanels(with: labels)
        }
        panelLabels = labels
        setShowing(true)
    }

    private func setShowing(_ showing: Bool) {
        isShowing = showing
        let midY = rowMidY
        stream.perform { [weak self] in
            self?.showingForQueue = showing
            self?.rowMidYForQueue = midY
            self?.verifyFullForQueue = false
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
        events.append("\(Self.timeString(Date(), withTenths: true)) \(message)")
        if events.count > 30 { events.removeFirst(events.count - 30) }
    }

    private static func timeString(_ date: Date, withTenths: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = withTenths ? "HH:mm:ss.S" : "HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: - 진단

    func diagnostics() -> String {
        var lines: [String] = []
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("접근성 권한: \(DockAccessibility.isTrusted ? "허용됨" : "없음")")
        lines.append("화면 기록 권한: \(ScreenText.hasScreenCaptureAccess ? "허용됨" : "없음 (시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음에서 DesktopNamer 켜기)")")
        lines.append("앱 위치: \(DockAccessibility.signingInfo())")
        lines.append("오버레이 실행 중: \(running ? "예" : "아니오"), 감시 모드: \(alwaysWatch ? "항상" : "동작 감지 시"), 화면 스트림: \(stream.isRunning ? "동작" : "정지")")
        lines.append("동작 감지: 트랙패드 \(trackpad.note) / 키보드 \(trigger.lastNote), 마지막 감지: \(lastTriggerNote)")
        lines.append("캡처 제외: \(stream.excludedNote)")
        lines.append("글자 인식: \(lastOCRNote)")
        if !lastOCRTexts.isEmpty {
            lines.append("인식된 글자: " + lastOCRTexts.joined(separator: " | "))
        }
        lines.append("라벨 줄 발견: \(foundCount)회, 마지막 \(lastFoundAt.map { Self.timeString($0) } ?? "없음")")
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
        panelLabels = []
        tracked.removeAll()
        setShowing(false)
    }

    /// 이름표 글자와 크기가 같으면 패널을 새로 만들지 않고 자리만 옮긴다 (깜빡임 없이 따라가기)
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
            let pill = Self.makeLabel(text: label.text, size: label.frame.size)
            let panel = NSPanel(
                contentRect: CGRect(origin: label.frame.origin, size: label.frame.size),
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
            panel.contentView = pill
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        updateCaptureExclusion()
    }

    /// 이름표 창들을 화면 스트림의 제외 목록에 넣는다 (캡처에 찍히면 원래 라벨을 가려 오판한다)
    private func updateCaptureExclusion() {
        var ids = Set(panels.map { CGWindowID($0.windowNumber) })
        if let anchorWindow { ids.insert(CGWindowID(anchorWindow.windowNumber)) }
        Task { [weak self] in
            await self?.stream.excludeWindows(ids: ids)
        }
    }

    /// 어두운 알약 배경 위에 흰 글씨. 정해진 크기에 맞추고 긴 글은 …로 줄인다.
    private static func makeLabel(text: String, size: CGSize) -> NSView {
        let pill = NSView(frame: CGRect(origin: .zero, size: size))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1.0).cgColor
        pill.layer?.cornerRadius = size.height / 2

        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: min(13, size.height - 8), weight: .medium)
        field.textColor = .white
        field.alignment = .center
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        let padding: CGFloat = 8
        let textHeight = field.font?.pointSize.rounded(.up).advanced(by: 4) ?? 17
        field.frame = CGRect(x: padding, y: (size.height - textHeight) / 2, width: size.width - padding * 2, height: textHeight)
        pill.addSubview(field)
        return pill
    }
}
