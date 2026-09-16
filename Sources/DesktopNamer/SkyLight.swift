import Foundation
import CoreGraphics

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

/// SkyLight(구 CoreGraphics Services)의 비공개 공간(Space) API를 dlsym으로 동적 로드한다. 읽기 전용으로만 쓴다.
/// 링커 플래그 없이 동작하고, 심볼이 없는 macOS에서는 `isAvailable`이 false가 된다.
enum SkyLight {
    private typealias MainConnectionFn = @convention(c) () -> CGSConnectionID
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
    private typealias GetActiveSpaceFn = @convention(c) (CGSConnectionID) -> CGSSpaceID
    private typealias CopySpacesForWindowsFn = @convention(c) (CGSConnectionID, UInt32, CFArray) -> Unmanaged<CFArray>?
    private typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) -> Void
    private typealias RegisterNotifyFn = @convention(c) (CGSConnectionID, NotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32

    /// kCGSAllSpacesMask: 현재 + 다른 + 사용자 공간 모두
    private static let allSpacesMask: UInt32 = 7

    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    }()

    private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    private static let mainConnection = symbol("CGSMainConnectionID", as: MainConnectionFn.self)
    private static let copyManagedDisplaySpaces = symbol("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self)
    private static let getActiveSpace = symbol("CGSGetActiveSpace", as: GetActiveSpaceFn.self)
    private static let copySpacesForWindows = symbol("CGSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
    private static let registerNotifyProc = symbol("SLSRegisterConnectionNotifyProc", as: RegisterNotifyFn.self)
        ?? symbol("CGSRegisterConnectionNotifyProc", as: RegisterNotifyFn.self)

    static var isAvailable: Bool {
        mainConnection != nil && copyManagedDisplaySpaces != nil && getActiveSpace != nil
    }

    private static var connection: CGSConnectionID? {
        mainConnection?()
    }

    /// 디스플레이별 공간 정보. 각 항목은 "Display Identifier", "Current Space", "Spaces" 키를 가진 사전이다.
    static func managedDisplaySpaces() -> [[String: Any]] {
        guard let cid = connection, let fn = copyManagedDisplaySpaces,
              let array = fn(cid)?.takeRetainedValue() else { return [] }
        return (array as NSArray) as? [[String: Any]] ?? []
    }

    static func activeSpaceID() -> CGSSpaceID? {
        guard let cid = connection, let fn = getActiveSpace else { return nil }
        return fn(cid)
    }

    // MARK: - Mission Control 알림

    /// Mission Control 관련 WindowServer 이벤트: 1204 전체 창 보기(열림), 1205 앱 창 보기, 1206 데스크탑 보기, 1207 닫힘
    static let missionControlEvents: [UInt32] = [1204, 1205, 1206, 1207]

    /// 메인 스레드에서 호출된다.
    static var onMissionControlEvent: ((UInt32) -> Void)?

    private static let notifyProc: NotifyProc = { type, _, _, _, _ in
        DispatchQueue.main.async { SkyLight.onMissionControlEvent?(type) }
    }

    /// Mission Control 열림/닫힘 알림을 등록한다. 결과 문자열은 진단용.
    static func registerMissionControlNotifications() -> String {
        guard let cid = connection else { return "연결 없음" }
        guard let fn = registerNotifyProc else { return "SLSRegisterConnectionNotifyProc 심볼 없음" }
        return missionControlEvents
            .map { "\($0)=\(fn(cid, notifyProc, $0, nil))" }
            .joined(separator: ", ")
    }

    private typealias SetCurrentSpaceFn = @convention(c) (CGSConnectionID, CFString, CGSSpaceID) -> Void
    private static let setCurrentSpace = symbol("CGSManagedDisplaySetCurrentSpace", as: SetCurrentSpaceFn.self)

    static var canSwitchDirectly: Bool { setCurrentSpace != nil }

    /// 공간을 직접 전환한다. Dock과 상태가 어긋날 수 있어, 배지 준비처럼 잠깐 도는 용도로만 쓴다.
    @discardableResult
    static func switchDirectly(to spaceID: CGSSpaceID, onDisplay displayID: String) -> Bool {
        guard let cid = connection, let fn = setCurrentSpace else { return false }
        fn(cid, displayID as CFString, spaceID)
        return true
    }

    /// 창이 속한 공간 ID 목록 (보통 1개, "모든 데스크탑" 창은 여러 개)
    static func spaceIDs(forWindow windowID: CGWindowID) -> [CGSSpaceID] {
        guard let cid = connection, let fn = copySpacesForWindows,
              let array = fn(cid, allSpacesMask, [NSNumber(value: windowID)] as CFArray)?.takeRetainedValue() else {
            return []
        }
        return ((array as NSArray) as? [NSNumber])?.map { $0.uint64Value } ?? []
    }
}
