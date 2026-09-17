import AppKit

/// Mission Control이 열린 순간과 닫힌 순간을 알려준다.
///
/// 두 가지를 함께 쓴다.
/// 1. 제스처/키 (빠름, 부정확): 세 손가락 위로 쓸기, ⌃↑, Mission Control 키.
///    macOS는 Mission Control을 열 때 지금 화면을 한 번 찍어 썸네일로 쓰므로,
///    그 순간보다 이름표가 늦으면 현재 데스크탑 썸네일에 안 찍힌다. 그래서 빠른 신호가 필요하다.
/// 2. Dock 창 개수 확인 (0.5초마다, 정확): 실제로 열려 있는지 확인한다.
///    이쪽이 "열려 있다"고 하는 동안에는 클릭·키 입력 같은 약한 닫힘 신호를 무시한다.
///    아직 배우지 못한 상태면 예전처럼 1번만으로 판단한다.
final class MissionControlSignals {
    /// 메인 스레드에서 호출된다.
    var onOpenLikely: ((String) -> Void)?
    var onCloseLikely: ((String) -> Void)?
    /// 아직 열려 있음이 확인될 때마다 호출된다 (자동 숨김 타이머를 미루기 위함)
    var onStillOpen: (() -> Void)?

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
    private(set) var isRunning = false
    private(set) var lastOpenNote = "없음"

    var note: String {
        "트랙패드 \(trackpad.diagnostics) / 키보드 \(keyboard.lastNote)"
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

        keyboard.onTrigger = { [weak self] reason in self?.open(reason) }
        keyboard.start(includeGestures: !trackpadWorks)

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // 데스크탑이 바뀌었다는 건 Mission Control에서 하나를 골랐거나 직접 전환한 것이다
            self?.close("데스크탑 전환", strong: true)
        })
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // Mission Control이 떠 있는 동안에는 Dock이 활성 앱이 되므로 Dock은 제외한다
            if app?.bundleIdentifier != "com.apple.dock" { self?.close("앱 전환") }
        })

        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            let reason = event.type == .keyDown ? "키 입력" : "클릭"
            // 클릭 직후 화면이 바뀌는 데 시간이 걸리므로 조금 늦게 판단한다
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.close(reason) }
        })
        if let monitor { inputMonitors.append(monitor) }

        // 스크롤은 평소 화면에서 작업 중이라는 뜻이다.
        // (마우스를 움직였다고 닫힌 것으로 보지는 않는다. Mission Control 안에서
        //  썸네일을 훑어보는 동안 이름이 먼저 사라져 버리기 때문이다.)
        let scroll = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] _ in
            self?.close("스크롤")
        })
        if let scroll { inputMonitors.append(scroll) }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        isRunning = false
        trackpad.stopMonitoring()
        keyboard.stop()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        inputMonitors.forEach { NSEvent.removeMonitor($0) }
        inputMonitors.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - 주기 확인

    private func poll() {
        let showing = isShowing?() == true
        guard showing else {
            closedPolls = 0
            // 닫은 직후에는 잔상이 남을 수 있으므로 조금 지난 뒤부터 기준선을 잰다
            if Date().timeIntervalSince(lastClosedAt) > 1.5 { probe.noteQuiet() }
            // 차이가 뚜렷하게 배워진 경우에만, 제스처를 놓쳤어도 열린 것을 알아챈다
            // (Mission Control 키, 핫코너, Dock 아이콘으로 연 경우)
            if probe.looksActiveStrict() == true,
               Date().timeIntervalSince(lastAutoOpenAt) > 2 {
                lastAutoOpenAt = Date()
                open("Mission Control 열림 확인")
            }
            return
        }

        switch probe.looksActive() {
        case .some(true):
            closedPolls = 0
            // 아직 열려 있다. 자동 숨김 타이머를 미뤄 이름이 먼저 사라지지 않게 한다.
            onStillOpen?()
        case .some(false):
            closedPolls += 1
            if closedPolls >= 2 { close("Mission Control 닫힘 확인", strong: true) }
        case .none:
            closedPolls = 0
        }
    }

    // MARK: - 열기/닫기

    private func open(_ reason: String) {
        let now = Date()
        // 같은 쓸기의 반복 감지는 무시
        if now.timeIntervalSince(lastGestureAt) < 0.4 { return }
        lastGestureAt = now

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        // 이미 보이는 중에 또 여는 동작이 들어오면 "닫기"로 해석한다.
        // 다만 Dock 창 개수로 아직 열려 있음이 확인되면 그쪽을 믿는다. (약한 신호로 넘긴다)
        if isShowing?() == true {
            lastOpenNote = "\(reason) → 닫기 (\(formatter.string(from: Date())))"
            close(reason + " (다시)")
            return
        }
        lastOpenNote = "\(reason) (\(formatter.string(from: Date())))"
        onOpenLikely?(reason)

        // 열린 직후의 Dock 창 개수를 재서 배운다. 애니메이션이 시작될 시간을 준다.
        for delay in [0.35, 0.7, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isShowing?() == true else { return }
                self.probe.noteOpen()
            }
        }
    }

    /// - Parameter strong: true면 실제 상태와 무관하게 닫는다.
    ///   false(약한 신호)는 Dock 창 개수가 "아직 열려 있다"고 하면 무시한다.
    private func close(_ reason: String, strong: Bool = false) {
        guard isShowing?() == true else { return }
        if !strong, probe.looksActive() == true { return }
        lastClosedAt = Date()
        closedPolls = 0
        onCloseLikely?(reason)
    }
}
