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
    /// 세 손가락 이상으로 아래로 쓸었을 때 (Mission Control 닫기)
    static var onSwipeDown: ((Int) -> Void)?

    /// 시험해 볼 (구조체 크기, y 위치) 후보들
    private static let candidates: [(stride: Int, yOffset: Int)] = {
        var list: [(stride: Int, yOffset: Int)] = []
        for stride in [96, 100, 104, 108, 112, 116, 120, 124, 128, 136, 144] {
            for yOffset in [28, 32, 36, 40, 44] where yOffset + 4 <= stride {
                list.append((stride, yOffset))
            }
        }
        return list
    }()
    /// 찾아낸 자리 (nil이면 아직 탐색 중)
    private static var layout: (stride: Int, yOffset: Int)?
    private static var probeFrames = 0
    /// 후보별 누적 점수(맞으면 +1, 틀리면 -1). 충분히 앞서면 확정한다.
    private static var candidateScores: [Int: Int] = [:]
    private static let scoreToConfirm = 20

    // 제스처 상태
    private static var startY: Float?
    private static var startCount = 0
    private static var fired = false
    /// 위로 쓸기로 인정할 최소 이동량 (0~1 정규화 좌표)
    private static let minimumRise: Float = 0.02

    // 진단
    private(set) static var lastCount = 0
    /// 그중 실제로 닿아 있던 손가락 수
    private(set) static var lastTouching = 0
    private(set) static var lastY: Float = -1
    private(set) static var lastRise: Float = 0
    static var swipeCount = 0
    private static var badReads = 0
    /// 탐색 중 후보별로 관찰한 y 값들 (실제로 움직였는지 보기 위함)
    private static var probeHistory: [Int: [Float]] = [:]
    static var layoutNote: String {
        guard let layout else {
            let ranked = candidateScores.sorted { $0.value > $1.value }.prefix(3)
            let detail = ranked.isEmpty ? "일치하는 후보 없음"
                : ranked.map { "\(candidates[$0.key].stride)/\(candidates[$0.key].yOffset)=\($0.value)" }.joined(separator: " ")
            return "손가락 위치 탐색 중 (프레임 \(probeFrames)개, 상위 후보 \(detail))"
        }
        return "구조체 \(layout.stride)바이트, y 위치 \(layout.yOffset)"
    }

    /// 확정한 자리가 틀렸을 때 다시 찾게 한다 (메뉴에서 호출)
    static func resetLayout() {
        layout = nil
        candidateScores.removeAll()
        probeHistory.removeAll()
        probeFrames = 0
        badReads = 0
        swipeCount = 0
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

    /// 후보가 맞는지 본다.
    /// MTTouch는 [frame(Int32), timestamp(Double), identifier(Int32), state(Int32), ...] 순서이고
    /// identifier는 1부터 차례로 붙는다. 이 값이 손가락 개수와 맞아떨어지는 후보가 진짜다.
    private static func isPlausible(_ touches: UnsafeMutableRawPointer, count: Int, candidate: (stride: Int, yOffset: Int)) -> Bool {
        var identifiers: Set<Int32> = []
        for index in 0..<count {
            let base = index * candidate.stride
            // identifier는 y 좌표보다 앞쪽에 있다 (정규화 좌표 직전 16바이트)
            let identifier = touches.load(fromByteOffset: base + candidate.yOffset - 20, as: Int32.self)
            guard identifier >= 1, identifier <= 20 else { return false }
            identifiers.insert(identifier)

            let x = touches.load(fromByteOffset: base + candidate.yOffset - 4, as: Float.self)
            let y = touches.load(fromByteOffset: base + candidate.yOffset, as: Float.self)
            guard x.isFinite, y.isFinite, x >= -0.05, x <= 1.05, y >= -0.05, y <= 1.05 else { return false }
        }
        // 손가락마다 서로 다른 식별자를 가져야 한다
        return identifiers.count == count
    }

    private static func averageY(_ touches: UnsafeMutableRawPointer, count: Int, candidate: (stride: Int, yOffset: Int)) -> Float {
        var sum: Float = 0
        for index in 0..<count {
            sum += touches.load(fromByteOffset: index * candidate.stride + candidate.yOffset, as: Float.self)
        }
        return sum / Float(count)
    }

    /// 실제로 트랙패드에 "닿아 있는" 손가락들의 y 좌표만 골라낸다.
    ///
    /// MultitouchSupport가 알려주는 손가락 개수에는 트랙패드 위에 살짝 떠 있거나
    /// 방금 뗀 손가락도 들어간다. 그대로 세면 두 손가락으로 쓸었는데 3개로 잡혀
    /// Mission Control 제스처로 오인한다.
    ///
    /// state 필드는 y 좌표보다 16바이트 앞에 있고, 값의 뜻은 다음과 같다.
    /// 1 추적 안 함, 2 범위 진입, 3 떠 있음, 4 닿기 시작, 5 닿아 있음,
    /// 6 떼는 중, 7 머무는 중, 8 범위 밖. 이 중 4와 5만 진짜로 누른 손가락이다.
    private static func touchingYs(_ touches: UnsafeMutableRawPointer, count: Int, candidate: (stride: Int, yOffset: Int)) -> [Float] {
        var states: [Int32] = []
        var ys: [Float] = []
        for index in 0..<count {
            let base = index * candidate.stride
            states.append(touches.load(fromByteOffset: base + candidate.yOffset - 16, as: Int32.self))
            ys.append(touches.load(fromByteOffset: base + candidate.yOffset, as: Float.self))
        }
        // 값이 예상 범위(1~8)를 벗어나면 그 자리가 state가 아니다. 그때는 전부 센다.
        guard states.allSatisfy({ $0 >= 1 && $0 <= 8 }) else { return ys }
        let touching = zip(states, ys).filter { $0.0 == 4 || $0.0 == 5 }.map { $0.1 }
        // 하나도 안 걸리면 판단이 안 되는 상황이므로 원래대로 전부 센다
        return touching.isEmpty ? ys : touching
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

        // 아직 자리를 못 찾았으면 후보를 점수로 가린다.
        // 범위 검사만으로는 우연히 통과하는 후보가 있어, "손가락이 실제로 움직인 기록"까지 본다.
        if layout == nil {
            probeFrames += 1
            guard count >= 2 else {
                probeHistory.removeAll()
                return 0
            }
            for (index, candidate) in candidates.enumerated() {
                guard isPlausible(touches, count: count, candidate: candidate) else {
                    candidateScores[index] = max(-5, (candidateScores[index] ?? 0) - 1)
                    probeHistory[index] = nil
                    continue
                }
                let y = averageY(touches, count: count, candidate: candidate)
                var history = probeHistory[index] ?? []
                history.append(y)
                if history.count > 40 { history.removeFirst() }
                probeHistory[index] = history
                // 식별자까지 맞으면 유력 후보. 움직임 폭이 확인되면 더 가점.
                var gain = 1
                if let low = history.min(), let high = history.max(), high - low > 0.02 {
                    gain = 4
                }
                candidateScores[index] = (candidateScores[index] ?? 0) + gain
            }
            let ranked = candidateScores.sorted { $0.value > $1.value }
            if let best = ranked.first, best.value >= scoreToConfirm {
                // 2등과 확실히 차이가 나야 채택한다
                let second = ranked.dropFirst().first?.value ?? 0
                if best.value >= second * 2 || best.value - second >= 10 {
                    layout = candidates[best.key]
                    probeHistory.removeAll()
                }
            }
            guard layout != nil else { return 0 }
        }
        guard let found = layout else { return 0 }

        let ys = touchingYs(touches, count: count, candidate: found)
        lastTouching = ys.count
        guard ys.count >= 3 else {
            startY = nil
            startCount = 0
            fired = false
            return 0
        }

        let y = ys.reduce(0, +) / Float(ys.count)
        guard y.isFinite, y >= -0.05, y <= 1.05 else {
            badReads += 1
            if badReads > 30 {
                // 잘못 찾은 자리다. 처음부터 다시 탐색한다.
                TrackpadMonitor.layout = nil
                candidateScores.removeAll()
                badReads = 0
            }
            return 0
        }
        badReads = 0
        lastY = y

        if startY == nil || ys.count != startCount {
            startY = y
            startCount = ys.count
            fired = false
            return 0
        }
        guard !fired, let origin = startY else { return 0 }

        let rise = y - origin
        lastRise = rise
        // 위아래로 충분히 움직였을 때만 알린다 (가만히 얹거나 좌우로 쓸면 반응하지 않음)
        if abs(rise) >= minimumRise {
            fired = true
            swipeCount += 1
            let fingers = ys.count
            let up = rise > 0
            DispatchQueue.main.async {
                up ? onSwipeUp?(fingers) : onSwipeDown?(fingers)
            }
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
        "\(note), \(Self.layoutNote), 마지막 손가락 \(Self.lastCount)개(닿음 \(Self.lastTouching)개) y=\(String(format: "%.3f", Self.lastY)) 이동 \(String(format: "%.3f", Self.lastRise)), 위로 쓸기 \(Self.swipeCount)회"
    }
}
