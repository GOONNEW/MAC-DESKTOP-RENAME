import AppKit

/// Mission Control이 열릴 것 같은 순간과 닫힌 것 같은 순간을 알려준다.
/// 이 macOS에서는 Mission Control 상태를 직접 알 수 없어, 사용자 동작으로 추정한다.
/// - 열림: 트랙패드 세 손가락 이상, ⌃↑, Mission Control 키
/// - 닫힘: 클릭, 키 입력, 데스크탑 전환, 앱 전환
final class MissionControlSignals {
    /// 메인 스레드에서 호출된다.
    var onOpenLikely: ((String) -> Void)?
    var onCloseLikely: ((String) -> Void)?

    /// 지금 이름이 보이는 중인지. 보이는 중에 들어온 여는 동작은 "닫기"로 해석한다.
    var isShowing: (() -> Bool)?

    private let trackpad = TrackpadMonitor()
    private let keyboard = MissionControlTrigger()
    private var mouseMonitor: Any?
    private var lastMouseLocation: NSPoint?
    /// 한 번의 쓸기에서 제스처가 여러 번 잡히므로, 이 시간 안의 재감지는 같은 동작으로 본다
    private var lastGestureAt = Date.distantPast
    private var trackpadWorks = false
    private var observers: [NSObjectProtocol] = []
    private var inputMonitors: [Any] = []
    private(set) var isRunning = false
    private(set) var lastOpenNote = "없음"

    var note: String {
        "트랙패드 \(trackpad.diagnostics) / 키보드 \(keyboard.lastNote)"
            + (keyboard.lastTouchCount >= 0 ? ", 마지막 제스처 손가락 \(keyboard.lastTouchCount)개" : "")
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        TrackpadMonitor.onSwipeUp = { [weak self] count in
            self?.open("트랙패드 \(count)손가락 위로 쓸기")
        }
        TrackpadMonitor.onSwipeDown = { [weak self] count in
            self?.onCloseLikely?("트랙패드 \(count)손가락 아래로 쓸기")
        }
        trackpadWorks = trackpad.startMonitoring()

        keyboard.onTrigger = { [weak self] reason in self?.open(reason) }
        keyboard.start(includeGestures: !trackpadWorks)

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onCloseLikely?("데스크탑 전환")
        })
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier != "com.apple.dock" { self?.onCloseLikely?("앱 전환") }
        })
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            let reason = event.type == .keyDown ? "키 입력" : "클릭"
            // 클릭 직후 화면이 바뀌는 데 시간이 걸리므로 조금 늦게 판단한다
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.onCloseLikely?(reason) }
        })
        if let monitor { inputMonitors.append(monitor) }

        // Mission Control이 닫히면 커서가 평소 화면 위에서 움직인다. 크게 움직이면 닫힌 것으로 본다.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .scrollWheel], handler: { [weak self] event in
            guard let self, self.isShowing?() == true else {
                self?.lastMouseLocation = NSEvent.mouseLocation
                return
            }
            if event.type == .scrollWheel {
                self.onCloseLikely?("스크롤")
                return
            }
            let now = NSEvent.mouseLocation
            defer { self.lastMouseLocation = now }
            guard let previous = self.lastMouseLocation else { return }
            let distance = hypot(now.x - previous.x, now.y - previous.y)
            if distance > 120 { self.onCloseLikely?("마우스 이동") }
        })
        if let mouseMonitor { inputMonitors.append(mouseMonitor) }
    }

    func stop() {
        isRunning = false
        trackpad.stopMonitoring()
        keyboard.stop()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        inputMonitors.forEach { NSEvent.removeMonitor($0) }
        inputMonitors.removeAll()
    }

    private func open(_ reason: String) {
        let now = Date()
        // 같은 쓸기의 반복 감지는 무시
        if now.timeIntervalSince(lastGestureAt) < 0.4 { return }
        lastGestureAt = now

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        // 이미 보이는 중이라면 같은 제스처는 "닫기"다 (세 손가락으로 열고 세 손가락으로 닫는 경우)
        if isShowing?() == true {
            lastOpenNote = "\(reason) → 닫기 (\(formatter.string(from: Date())))"
            onCloseLikely?(reason + " (다시)")
            return
        }
        lastOpenNote = "\(reason) (\(formatter.string(from: Date())))"
        lastMouseLocation = NSEvent.mouseLocation
        onOpenLikely?(reason)
    }
}
