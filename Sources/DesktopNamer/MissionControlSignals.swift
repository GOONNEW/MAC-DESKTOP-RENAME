import AppKit

/// Mission Control이 열릴 것 같은 순간과 닫힌 것 같은 순간을 알려준다.
/// 이 macOS에서는 Mission Control 상태를 직접 알 수 없어, 사용자 동작으로 추정한다.
/// - 열림: 트랙패드 세 손가락 이상, ⌃↑, Mission Control 키
/// - 닫힘: 클릭, 키 입력, 데스크탑 전환, 앱 전환
final class MissionControlSignals {
    /// 메인 스레드에서 호출된다.
    var onOpenLikely: ((String) -> Void)?
    var onCloseLikely: ((String) -> Void)?

    private let trackpad = TrackpadMonitor()
    private let keyboard = MissionControlTrigger()
    private var trackpadWorks = false
    private var observers: [NSObjectProtocol] = []
    private var inputMonitors: [Any] = []
    private(set) var isRunning = false
    private(set) var lastOpenNote = "없음"

    var note: String {
        "트랙패드 \(trackpad.note) / 키보드 \(keyboard.lastNote)"
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        TrackpadMonitor.onTouchCountChanged = { [weak self] count in
            if count >= 3 { self?.open("트랙패드 \(count)손가락") }
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
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .keyDown], handler: { [weak self] event in
            let reason = event.type == .keyDown ? "키 입력" : "클릭"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.onCloseLikely?(reason) }
        })
        if let monitor { inputMonitors.append(monitor) }
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
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        lastOpenNote = "\(reason) (\(formatter.string(from: Date())))"
        onOpenLikely?(reason)
    }
}
