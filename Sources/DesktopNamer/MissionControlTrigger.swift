import AppKit
import CoreGraphics

/// Mission Control을 여는 사용자 동작(⌃↑, Mission Control 키, 트랙패드 제스처)을 감지한다.
/// 화면 감시를 항상 켜 두면 메뉴 막대에 화면 기록 표시가 계속 뜨므로, 이 신호가 있을 때만 잠깐 켠다.
final class MissionControlTrigger {
    /// 메인 스레드에서 호출된다. 인자는 감지한 동작의 이름.
    var onTrigger: ((String) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var lastNote = "시작 안 됨"
    /// 마지막 제스처의 손가락 개수 (진단용, 0이면 알 수 없음)
    private(set) var lastTouchCount = -1

    // NSEvent 타입 번호 (CGEventType에는 이름이 없지만 이벤트 탭으로 받을 수 있다)
    private static let beginGesture: UInt32 = 19
    private static let endGesture: UInt32 = 20
    private static let gesture: UInt32 = 29
    private static let magnify: UInt32 = 30
    private static let swipe: UInt32 = 31

    @discardableResult
    func start(includeGestures: Bool) -> Bool {
        guard tap == nil else { return true }
        var mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        if includeGestures {
            // 확대(magnify)는 두 손가락 핀치라 Mission Control과 무관하므로 넣지 않는다
            for type in [Self.beginGesture, Self.gesture, Self.swipe] {
                mask |= 1 << CGEventMask(type)
            }
        }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo {
                let trigger = Unmanaged<MissionControlTrigger>.fromOpaque(userInfo).takeUnretainedValue()
                trigger.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            lastNote = "이벤트 탭 생성 실패 (접근성 권한 확인)"
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            lastNote = "런루프 소스 생성 실패"
            return false
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lastNote = includeGestures ? "감시 중 (키보드, 트랙패드 제스처)" : "감시 중 (키보드)"
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        lastNote = "정지"
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type.rawValue {
        case CGEventType.keyDown.rawValue:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 160 {
                fire("Mission Control 키")
            } else if keyCode == 126, event.flags.contains(.maskControl) {
                fire("⌃↑")
            }
        case Self.beginGesture, Self.gesture, Self.swipe:
            let nsEvent = NSEvent(cgEvent: event)
            // CGEvent를 NSEvent로 바꾸면 손가락 정보가 사라지는 경우가 많다.
            // 그럴 때는 트랙패드 감시기가 방금 본 손가락 개수를 대신 쓴다.
            let reported = nsEvent?.allTouches().count ?? 0
            let fingers = reported > 0 ? reported : TrackpadMonitor.lastCount
            lastTouchCount = fingers
            if fingers >= 3 {
                fire("트랙패드 \(fingers)손가락 제스처")
                return
            }
            // 1~2개면 두 손가락 스크롤 같은 다른 동작이다. 반응하지 않는다.
            guard fingers == 0 else { return }
            // 개수를 끝내 알 수 없을 때만, 세로 방향 "쓸기"로 한정해 인정한다.
            // 두 손가락 스크롤은 .scrollWheel이라 여기로 오지 않고,
            // 좌우 페이지 넘김은 deltaX만 움직이므로 걸러진다.
            guard type.rawValue == Self.swipe, let nsEvent,
                  nsEvent.deltaY != 0, nsEvent.deltaX == 0 else { return }
            fire("트랙패드 세로 쓸기")
        case CGEventType.tapDisabledByTimeout.rawValue, CGEventType.tapDisabledByUserInput.rawValue:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            break
        }
    }

    private func fire(_ reason: String) {
        DispatchQueue.main.async { [weak self] in self?.onTrigger?(reason) }
    }
}
