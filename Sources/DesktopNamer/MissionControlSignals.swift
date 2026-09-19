import AppKit

/// Mission Control이 열린 순간과 닫힌 순간을 알려준다.
///
/// 세 가지를 함께 쓴다.
/// 1. WindowServer 알림 (가장 정확): Mission Control이 열리고 닫힐 때 macOS가 직접 알려준다.
///    이게 한 번이라도 오면 이것만 믿는다.
/// 2. 제스처/키 (가장 빠름): 세 손가락 위로 쓸기, ⌃↑, Mission Control 키.
///    macOS는 Mission Control을 열 때 지금 화면을 한 번 찍어 썸네일로 쓰므로,
///    그 순간보다 이름표가 늦으면 현재 데스크탑 썸네일에 안 찍힌다. 그래서 빠른 신호가 필요하다.
/// 3. 화면 지표 (알림이 안 올 때의 대비책): 0.5초마다 창 상태를 재서 열림/닫힘을 가린다.
final class MissionControlSignals {
    /// 메인 스레드에서 호출된다.
    var onOpenLikely: ((String) -> Void)?
    /// 두 번째 인자가 true면 막 띄운 직후여도 즉시 숨긴다
    var onCloseLikely: ((String, Bool) -> Void)?
    /// 아직 열려 있음이 확인될 때마다 호출된다 (자동 숨김 타이머를 미루기 위함)
    var onStillOpen: (() -> Void)?
    /// 열려 있는 동안 자주 호출된다 (공간 막대 위 이름표 위치를 맞추기 위함)
    var onTick: (() -> Void)?

    /// 지금 이름이 보이는 중인지. 보이는 중에 들어온 여는 동작은 "닫기"로 해석한다.
    var isShowing: (() -> Bool)?

    private let trackpad = TrackpadMonitor()
    private let keyboard = MissionControlTrigger()
    private let probe = MissionControlProbe()
    /// 한 번의 쓸기에서 제스처가 여러 번 잡히므로, 이 시간 안의 재감지는 같은 동작으로 본다
    private var lastGestureAt = Date.distantPast
    private var trackpadWorks = false
    private var observers: [NSObjectProtocol] = []
    private var inputMonitors: [Any] = []
    private var pollTimer: Timer?
    /// 연속으로 "닫힌 것 같다"고 본 횟수 (한 번은 흔들림일 수 있어 두 번 확인한다)
    private var closedPolls = 0
    private var lastClosedAt = Date.distantPast
    private var lastAutoOpenAt = Date.distantPast
    private var ticks = 0
    /// 화면 지표가 연속으로 "열렸다"고 본 횟수
    private var metricOpens = 0
    /// 이 시각까지는 다시 열지 않는다 (닫은 직후의 잔여 신호로 되살아나지 않게)
    private var reopenBlockedUntil = Date.distantPast
    /// 열려 있다는 판단 때문에 약한 닫힘 신호를 무시한 횟수
    private var ignoredCloses = 0
    /// 이름표를 띄운 시각
    private var shownAt: Date?
    private(set) var isRunning = false
    private(set) var lastOpenNote = "없음"

    var note: String {
        "열림 판단 근거: \(axWorks ? "접근성 트리 (가장 확실)" : "알림/화면 지표")"
            + "\n  트랙패드 \(trackpad.diagnostics) / 키보드 \(keyboard.lastNote)"
            + (keyboard.lastTouchCount >= 0 ? ", 마지막 제스처 손가락 \(keyboard.lastTouchCount)개" : "")
            + "\n열림 확인: \(probe.note)"
    }

    /// 배운 Dock 창 개수를 버리고 다시 관찰한다 (메뉴에서 호출)
    func resetProbe() {
        probe.reset()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        TrackpadMonitor.onSwipeUp = { [weak self] count in
            self?.open("트랙패드 \(count)손가락 위로 쓸기")
        }
        TrackpadMonitor.onSwipeDown = { [weak self] count in
            self?.close("트랙패드 \(count)손가락 아래로 쓸기", strong: true)
        }
        trackpadWorks = trackpad.startMonitoring()

        // WindowServer가 Mission Control 열림/닫힘을 직접 알려준다. 가장 정확한 신호다.
        SkyLight.onMissionControlEvent = { [weak self] type in self?.handleWindowServerEvent(type) }
        probe.noteRegistered(SkyLight.registerMissionControlNotifications())

        keyboard.onTrigger = { [weak self] reason in self?.open(reason) }
        keyboard.start(includeGestures: !trackpadWorks)

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // 데스크탑이 바뀌었다는 건 Mission Control에서 하나를 골랐거나 직접 전환한 것이다
            // 미션 컨트롤에서 데스크탑을 골랐거나 직접 전환한 것이다. 확실한 닫힘이다.
            self?.close("데스크탑 전환", strong: true, blockReopen: 1.2)
        })
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // Mission Control이 떠 있는 동안에는 Dock이 활성 앱이 되므로 Dock은 제외한다
            if app?.bundleIdentifier != "com.apple.dock" { self?.close("앱 전환") }
        })

        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            let reason = event.type == .keyDown ? "키 입력" : "클릭"
            // 이미 닫혔음이 확인되면 기다리지 않고 바로 숨긴다
            self?.closeIfConfirmed(reason)
            // 클릭 직후 화면이 바뀌는 데 시간이 걸리므로 조금 뒤 한 번 더 본다
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.close(reason) }
        })
        if let monitor { inputMonitors.append(monitor) }

        // 스크롤은 평소 화면에서 작업 중이라는 뜻이다.
        // (마우스를 움직였다고 닫힌 것으로 보지는 않는다. Mission Control 안에서
        //  썸네일을 훑어보는 동안 이름이 먼저 사라져 버리기 때문이다.)
        let scroll = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] _ in
            self?.closeIfConfirmed("스크롤")
            self?.close("스크롤")
        })
        if let scroll { inputMonitors.append(scroll) }

        // 열려 있는 동안 썸네일 위 이름표가 따라가야 하므로 촘촘히 본다.
        // 접근성 트리를 읽는 건 가벼운 편이고, 화면 지표는 아래에서 드문드문만 잰다.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        isRunning = false
        SkyLight.onMissionControlEvent = nil
        trackpad.stopMonitoring()
        keyboard.stop()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        inputMonitors.forEach { NSEvent.removeMonitor($0) }
        inputMonitors.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - WindowServer 알림

    /// 1204 Mission Control 열림 / 1205 앱 창 보기 / 1206 데스크탑 보기 / 1207 닫힘
    private func handleWindowServerEvent(_ type: UInt32) {
        probe.noteNotification(type)
        switch type {
        case 1204:
            open("Mission Control 알림")
        case 1205:
            // 앱 창 보기(App Exposé)는 데스크탑 썸네일이 아니므로 이름을 띄우지 않는다
            close("앱 창 보기", strong: true, blockReopen: 0.8)
        case 1206:
            close("데스크탑 보기", strong: true, blockReopen: 0.8)
        default:
            close("Mission Control 닫힘 알림", strong: true, blockReopen: 0.6)
        }
    }

    // MARK: - 주기 확인

    /// 지금 Mission Control이 열려 있는가. 모르면 nil.
    ///
    /// 접근성 트리에 공간 막대가 보이면 그것이 가장 확실하다. 추측이 아니라 확인이다.
    /// 권한이 없거나 구조가 바뀌어 못 읽으면 예전 방식(알림/화면 지표)으로 넘어간다.
    private func missionControlIsOpen() -> Bool? {
        if let byTree = SpacesBarAX.isOpen() {
            axWorks = true
            return byTree
        }
        return probe.looksActive()
    }

    /// 접근성 트리로 판단할 수 있는가 (진단용)
    private(set) var axWorks = false

    private func poll() {
        ticks += 1
        // 공간 막대 위 이름표는 제스처 판단과 상관없이 항상 맞춘다.
        // 열려 있으면 그리고, 닫혔으면 스스로 지운다. 추측에 기대지 않는 유일한 경로다.
        onTick?()

        let showing = isShowing?() == true
        guard showing else {
            closedPolls = 0
            // 화면 지표는 창 목록을 통째로 읽어야 해서 비싸다. 1초에 한 번만 잰다.
            // 닫은 직후에는 잔상이 남을 수 있으므로 조금 지난 뒤부터 잰다.
            if probe.usesMetrics, ticks % 5 == 0, Date().timeIntervalSince(lastClosedAt) > 1.5 {
                probe.noteQuiet()
            }
            // 제스처를 놓쳤어도 열린 것을 알아챈다
            // (Mission Control 키, 핫코너, Dock 아이콘으로 연 경우)
            //
            // 접근성 트리가 답하면 그것만 믿는다. 예전에는 "트리가 열림" 또는 "지표가 열림"
            // 중 하나만 맞으면 열었는데, 트리가 "닫힘"이라고 해도 지표가 오판하면 열려 버렸다.
            // 실제로 2초마다 혼자 떴다 사라지기를 반복했다. 지표는 창 개수 같은 값이라
            // 평소 작업 중에도 흔들린다. 확실한 근거가 있으면 흔들리는 쪽은 보지 않는다.
            let confirmed: Bool
            switch SpacesBarAX.isOpen() {
            case .some(let openByTree):
                confirmed = openByTree
                metricOpens = 0
            case .none:
                // 트리를 못 읽을 때만 지표를 쓴다. 한 번의 흔들림으로 열지 않도록
                // 연속 두 번 같은 답이 나와야 인정한다.
                metricOpens = probe.looksActiveStrict() == true ? metricOpens + 1 : 0
                confirmed = metricOpens >= 2
            }
            if confirmed, Date().timeIntervalSince(lastAutoOpenAt) > 2 {
                lastAutoOpenAt = Date()
                metricOpens = 0
                open("Mission Control 열림 확인", automatic: true)
            }
            return
        }

        switch missionControlIsOpen() {
        case .some(true):
            closedPolls = 0
            // 아직 열려 있다. 자동 숨김 타이머를 미뤄 이름이 먼저 사라지지 않게 한다.
            onStillOpen?()
        case .some(false):
            closedPolls += 1
            if closedPolls >= 3 { close("Mission Control 닫힘 확인", strong: true) }
        case .none:
            closedPolls = 0
        }
    }

    // MARK: - 열기/닫기

    /// - Parameter automatic: 사용자가 한 동작이 아니라 화면 지표로 추측한 열림.
    ///   이 경우에만 "방금 닫았으니 잠시 열지 말기"를 적용한다.
    ///   제스처나 WindowServer 알림은 사용자의 뜻이거나 확실한 사실이므로 절대 막지 않는다.
    private func open(_ reason: String, automatic: Bool = false) {
        let now = Date()
        if automatic, now < reopenBlockedUntil { return }
        // 같은 쓸기의 반복 감지는 무시
        if now.timeIntervalSince(lastGestureAt) < 0.4 { return }
        lastGestureAt = now

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        // 이미 보이는 중에 또 여는 동작이 들어오면 "닫기"로 해석한다.
        // 다만 아직 열려 있음이 확인되면 그쪽을 믿는다. (약한 신호로 넘긴다)
        if isShowing?() == true {
            lastOpenNote = "\(reason) → 닫기 (\(formatter.string(from: Date())))"
            close(reason + " (다시)")
            return
        }
        lastOpenNote = "\(reason) (\(formatter.string(from: Date())))"
        shownAt = Date()
        ignoredCloses = 0
        onOpenLikely?(reason)

        // 열린 직후의 화면 지표를 재서 배운다. 애니메이션이 시작될 시간을 준다.
        guard probe.usesMetrics else { return }
        for delay in [0.35, 0.7, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.probe.usesMetrics, self.isShowing?() == true else { return }
                self.probe.noteOpen()
            }
        }
    }

    /// 실제로 닫혔음이 확인된 경우에만 즉시 닫는다.
    /// 열림 여부를 모르는 상태(nil)에서는 아무것도 하지 않아, 예전 동작을 그대로 남긴다.
    private func closeIfConfirmed(_ reason: String) {
        guard missionControlIsOpen() == false else { return }
        close(reason, strong: true, blockReopen: 0.4)
    }

    /// - Parameters:
    ///   - strong: true면 실제 상태와 무관하게 닫는다.
    ///     false(약한 신호)는 "아직 열려 있다"고 판단되면 무시한다.
    ///   - blockReopen: 닫은 뒤 이 시간 동안은 다시 열지 않는다.
    private func close(_ reason: String, strong: Bool = false, blockReopen: TimeInterval = 0) {
        guard isShowing?() == true else { return }

        if !strong, missionControlIsOpen() == true {
            // 열려 있는 동안 클릭·스크롤을 무시하는 것은 원래 의도한 동작이다.
            // (미션 컨트롤을 구경하는 중에 이름표가 꺼지지 않게 하려는 것)
            // 그러니 이것만으로 판단이 틀렸다고 보면 안 된다. 실제로 그렇게 했더니
            // 멀쩡한 지표까지 줄줄이 버려졌다. 여기서는 세기만 하고, 너무 오래
            // 이어질 때만 마지막 수단으로 끊는다.
            ignoredCloses += 1
            guard ignoredCloses >= 12, showingLongerThan(8) else { return }
            probe.distrust()
            ignoredCloses = 0
            finishClose(reason + " (열림 판단이 너무 오래 이어짐)", force: true, blockReopen: blockReopen)
            return
        }

        ignoredCloses = 0
        finishClose(reason, force: strong, blockReopen: blockReopen)
    }

    /// 이름표가 이 시간보다 오래 보이고 있는가
    private func showingLongerThan(_ seconds: TimeInterval) -> Bool {
        guard let shownAt else { return false }
        return Date().timeIntervalSince(shownAt) > seconds
    }

    private func finishClose(_ reason: String, force: Bool, blockReopen: TimeInterval) {
        if blockReopen > 0 {
            reopenBlockedUntil = max(reopenBlockedUntil, Date().addingTimeInterval(blockReopen))
        }
        lastClosedAt = Date()
        closedPolls = 0
        shownAt = nil
        onCloseLikely?(reason, force)

        // 확실하게 닫은 다음에도 지표가 "아직 열려 있다"고 하면, 그 지표가 틀린 것이다.
        // 이건 진짜 모순이라 근거로 삼을 수 있다. 닫히는 애니메이션이 끝날 시간을 준 뒤 본다.
        guard force else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.isShowing?() != true else { return }
            guard self.probe.looksActive() == true else { return }
            // 접근성 트리로 판단 중이라면 화면 지표는 쓰이지 않으므로 버릴 것도 없다
            guard !self.axWorks else { return }
            self.probe.distrust()
        }
    }
}
