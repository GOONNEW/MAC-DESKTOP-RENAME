import Foundation

/// 트랙패드에 닿은 손가락 개수를 직접 읽는다 (비공개 MultitouchSupport 프레임워크).
/// 이벤트 탭으로는 손가락 개수를 알 수 없어, 두 손가락 스크롤과 세 손가락 쓸기를 구분하려면 이 방법이 필요하다.
final class TrackpadMonitor {
    private typealias DeviceRef = UnsafeMutableRawPointer
    private typealias ContactCallback = @convention(c) (DeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterFn = @convention(c) (DeviceRef?, ContactCallback?) -> Void
    private typealias StartFn = @convention(c) (DeviceRef?, Int32) -> Void
    private typealias StopFn = @convention(c) (DeviceRef?) -> Void

    /// 메인 스레드에서, 손가락 개수가 바뀔 때마다 호출된다.
    static var onTouchCountChanged: ((Int) -> Void)?
    private static var lastCount = -1

    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
    }()

    private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    private static let createList = symbol("MTDeviceCreateList", as: CreateListFn.self)
    private static let register = symbol("MTRegisterContactFrameCallback", as: RegisterFn.self)
    private static let start = symbol("MTDeviceStart", as: StartFn.self)
    private static let stop = symbol("MTDeviceStop", as: StopFn.self)

    private static let callback: ContactCallback = { _, _, touchCount, _, _ in
        let count = Int(touchCount)
        if count != lastCount {
            lastCount = count
            DispatchQueue.main.async { onTouchCountChanged?(count) }
        }
        return 0
    }

    private var devices: [DeviceRef] = []
    private(set) var note = "시작 안 됨"

    static var isAvailable: Bool {
        createList != nil && register != nil && start != nil
    }

    @discardableResult
    func startMonitoring() -> Bool {
        guard devices.isEmpty else { return true }
        guard let createList = Self.createList, let register = Self.register, let start = Self.start else {
            note = "MultitouchSupport 심볼 없음"
            return false
        }
        guard let list = createList()?.takeRetainedValue() else {
            note = "트랙패드 장치 목록 없음"
            return false
        }
        let count = CFArrayGetCount(list)
        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = DeviceRef(mutating: pointer)
            register(device, Self.callback)
            start(device, 0)
            devices.append(device)
        }
        note = devices.isEmpty ? "트랙패드 장치 없음" : "트랙패드 \(devices.count)개 감시 중"
        return !devices.isEmpty
    }

    func stopMonitoring() {
        guard let stop = Self.stop else { return }
        devices.forEach { stop($0) }
        devices.removeAll()
        note = "정지"
    }
}
