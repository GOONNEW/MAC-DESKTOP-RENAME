import Foundation

/// 트랙패드의 손가락 위치를 직접 읽어 "세 손가락 이상으로 위로 쓸기"를 감지한다.
/// (비공개 MultitouchSupport 프레임워크. 이벤트 탭으로는 손가락 개수와 방향을 알 수 없다.)
final class TrackpadMonitor {
    /// MultitouchSupport의 접촉 정보. 필드 순서는 고정되어 있다.
    private struct MTPoint { var x: Float; var y: Float }
    private struct MTReadout {
        var position: MTPoint
        var velocity: MTPoint
    }
    private struct MTTouch {
        var frame: Int32
        var timestamp: Double
        var identifier: Int32
        var state: Int32
        var unknown1: Int32
        var unknown2: Int32
        var normalized: MTReadout
        var size: Float
        var unknown3: Int32
        var angle: Float
        var majorAxis: Float
        var minorAxis: Float
        var absolute: MTReadout
        var unknown4: Int32
        var unknown5: Int32
        var density: Float
    }

    private typealias DeviceRef = UnsafeMutableRawPointer
    private typealias ContactCallback = @convention(c) (DeviceRef?, UnsafePointer<MTTouch>?, Int32, Double, Int32) -> Int32
    private typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterFn = @convention(c) (DeviceRef?, ContactCallback?) -> Void
    private typealias StartFn = @convention(c) (DeviceRef?, Int32) -> Void
    private typealias StopFn = @convention(c) (DeviceRef?) -> Void

    /// 메인 스레드에서, 세 손가락 이상으로 위로 쓸었을 때 호출된다. 인자는 손가락 개수.
    static var onSwipeUp: ((Int) -> Void)?

    /// 제스처 시작 시점의 평균 y 위치와 손가락 개수
    private static var startY: Float?
    private static var startCount = 0
    private static var fired = false
    /// 위로 쓸기로 인정할 최소 이동량 (트랙패드 세로 길이 대비)
    private static let minimumRise: Float = 0.08

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

    private static let callback: ContactCallback = { _, touches, touchCount, _, _ in
        let count = Int(touchCount)

        // 손가락이 3개 미만이면 제스처가 끝난 것
        guard count >= 3, let touches else {
            startY = nil
            startCount = 0
            fired = false
            return 0
        }

        // 손가락들의 평균 세로 위치 (0이 아래, 1이 위)
        var sum: Float = 0
        for index in 0..<count {
            sum += touches[index].normalized.position.y
        }
        let averageY = sum / Float(count)

        if startY == nil || count != startCount {
            startY = averageY
            startCount = count
            fired = false
            return 0
        }
        guard !fired, let origin = startY else { return 0 }

        // 위로 충분히 올라갔을 때만 알린다 (가만히 얹거나 좌우로 쓸면 반응하지 않음)
        if averageY - origin >= minimumRise {
            fired = true
            let fingers = count
            DispatchQueue.main.async { onSwipeUp?(fingers) }
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
        note = devices.isEmpty ? "트랙패드 장치 없음" : "트랙패드 \(devices.count)개 감시 중 (위로 쓸기)"
        return !devices.isEmpty
    }

    func stopMonitoring() {
        guard let stop = Self.stop else { return }
        devices.forEach { stop($0) }
        devices.removeAll()
        Self.startY = nil
        Self.fired = false
        note = "정지"
    }
}
