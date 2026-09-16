import Foundation

/// 트랙패드의 손가락 위치를 직접 읽어 "세 손가락 이상으로 위로 쓸기"를 감지한다.
/// (비공개 MultitouchSupport 프레임워크. 이벤트 탭으로는 손가락 개수와 방향을 알 수 없다.)
///
/// 접촉 구조체의 크기와 필드 위치는 macOS 버전마다 다를 수 있어, 처음 몇 프레임 동안
/// 여러 후보를 시험해 "0~1 범위의 좌표 한 쌍"이 나오는 자리를 자동으로 찾는다.
final class TrackpadMonitor {
    private typealias DeviceRef = UnsafeMutableRawPointer
    /// @convention(c)에는 Swift 구조체를 쓸 수 없어 원시 포인터로 받는다.
    private typealias ContactCallback = @convention(c) (DeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterFn = @convention(c) (DeviceRef?, ContactCallback?) -> Void
    private typealias StartFn = @convention(c) (DeviceRef?, Int32) -> Void
    private typealias StopFn = @convention(c) (DeviceRef?) -> Void

    /// 메인 스레드에서, 세 손가락 이상으로 위로 쓸었을 때 호출된다. 인자는 손가락 개수.
    static var onSwipeUp: ((Int) -> Void)?

    /// 시험해 볼 (구조체 크기, y 위치) 후보들
    private static let candidates: [(stride: Int, yOffset: Int)] = [
        (112, 36), (112, 32), (108, 32), (104, 32), (96, 32), (120, 36), (128, 40), (144, 40),
    ]
    /// 찾아낸 자리 (nil이면 아직 탐색 중)
    private static var layout: (stride: Int, yOffset: Int)?
    private static var probeFrames = 0
    /// 후보별 누적 점수(맞으면 +1, 틀리면 -1). 충분히 앞서면 확정한다.
    private static var candidateScores: [Int: Int] = [:]
    private static let scoreToConfirm = 8

    // 제스처 상태
    private static var startY: Float?
    private static var startCount = 0
    private static var fired = false
    /// 위로 쓸기로 인정할 최소 이동량 (0~1 정규화 좌표)
    private static let minimumRise: Float = 0.06

    // 진단
    private(set) static var lastCount = 0
    private(set) static var lastY: Float = -1
    private(set) static var lastRise: Float = 0
    private(set) static var swipeCount = 0
    private static var badReads = 0
    static var layoutNote: String {
        guard let layout else { return "손가락 위치 탐색 중 (프레임 \(probeFrames)개)" }
        return "구조체 \(layout.stride)바이트, y 위치 \(layout.yOffset)"
    }

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

    /// 후보가 맞는지 본다: 모든 손가락의 x, y가 0~1 안에 들어와야 한다.
    private static func isPlausible(_ touches: UnsafeMutableRawPointer, count: Int, candidate: (stride: Int, yOffset: Int)) -> Bool {
        var xs: [Float] = []
        var ys: [Float] = []
        for index in 0..<count {
            let base = index * candidate.stride
            let x = touches.load(fromByteOffset: base + candidate.yOffset - 4, as: Float.self)
            let y = touches.load(fromByteOffset: base + candidate.yOffset, as: Float.self)
            // 좌표는 0~1 범위 (가장자리 접촉을 감안해 약간 여유를 둔다)
            guard x.isFinite, y.isFinite, x >= -0.05, x <= 1.05, y >= -0.05, y <= 1.05 else { return false }
            xs.append(x)
            ys.append(y)
        }
        // 손가락들이 모두 같은 값이면 다른 필드를 읽은 것이다
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return false }
        return (maxX - minX) > 0.005 || (maxY - minY) > 0.005
    }

    private static func averageY(_ touches: UnsafeMutableRawPointer, count: Int, candidate: (stride: Int, yOffset: Int)) -> Float {
        var sum: Float = 0
        for index in 0..<count {
            sum += touches.load(fromByteOffset: index * candidate.stride + candidate.yOffset, as: Float.self)
        }
        return sum / Float(count)
    }

    private static let callback: ContactCallback = { _, touches, touchCount, _, _ in
        let count = Int(touchCount)
        lastCount = count

        guard count >= 1, count <= 11, let touches else {
            startY = nil
            startCount = 0
            fired = false
            return 0
        }

        // 아직 자리를 못 찾았으면 후보를 점수로 가린다. 손가락이 많을수록 판별력이 높다.
        if layout == nil {
            probeFrames += 1
            guard count >= 2 else { return 0 }
            for (index, candidate) in candidates.enumerated() {
                let score = (candidateScores[index] ?? 0)
                    + (isPlausible(touches, count: count, candidate: candidate) ? 1 : -1)
                candidateScores[index] = max(-5, min(score, scoreToConfirm))
            }
            // 가장 높은 점수가 기준을 넘고 2등과 차이가 나면 확정한다
            let ranked = candidateScores.sorted { $0.value > $1.value }
            if let best = ranked.first, best.value >= scoreToConfirm {
                let second = ranked.dropFirst().first?.value ?? -5
                if best.value > second || probeFrames > 200 {
                    layout = candidates[best.key]
                }
            }
            guard layout != nil else { return 0 }
        }
        guard let layout else { return 0 }

        guard count >= 3 else {
            startY = nil
            startCount = 0
            fired = false
            return 0
        }

        let y = averageY(touches, count: count, candidate: layout)
        guard y.isFinite, y >= -0.05, y <= 1.05 else {
            badReads += 1
            if badReads > 30 {
                // 잘못 찾은 자리다. 처음부터 다시 탐색한다.
                self.layout = nil
                candidateScores.removeAll()
                badReads = 0
            }
            return 0
        }
        badReads = 0
        lastY = y

        if startY == nil || count != startCount {
            startY = y
            startCount = count
            fired = false
            return 0
        }
        guard !fired, let origin = startY else { return 0 }

        let rise = y - origin
        lastRise = rise
        // 위로 충분히 올라갔을 때만 알린다 (가만히 얹거나 좌우로 쓸면 반응하지 않음)
        if rise >= minimumRise {
            fired = true
            swipeCount += 1
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
        note = devices.isEmpty ? "트랙패드 장치 없음" : "트랙패드 \(devices.count)개"
        return !devices.isEmpty
    }

    func stopMonitoring() {
        guard let stop = Self.stop else { return }
        devices.forEach { stop($0) }
        devices.removeAll()
        Self.startY = nil
        Self.fired = false
        Self.layout = nil
        Self.candidateScores.removeAll()
        note = "정지"
    }

    var diagnostics: String {
        "\(note), \(Self.layoutNote), 마지막 손가락 \(Self.lastCount)개 y=\(String(format: "%.3f", Self.lastY)) 이동 \(String(format: "%.3f", Self.lastRise)), 위로 쓸기 \(Self.swipeCount)회"
    }
}
