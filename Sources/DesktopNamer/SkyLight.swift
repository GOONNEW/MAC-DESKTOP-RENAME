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
    /// 연결(connection)마다 등록하는 알림 콜백. 마지막 인자로 연결 ID가 온다.
    private typealias ConnectionNotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) -> Void
    private typealias RegisterConnectionNotifyFn = @convention(c) (CGSConnectionID, ConnectionNotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32
    /// 프로세스 전체에 등록하는 알림 콜백 (연결 ID 없음)
    private typealias GlobalNotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void
    private typealias RegisterGlobalNotifyFn = @convention(c) (GlobalNotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32

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
    private static let registerConnectionNotify = symbol("SLSRegisterConnectionNotifyProc", as: RegisterConnectionNotifyFn.self)
        ?? symbol("CGSRegisterConnectionNotifyProc", as: RegisterConnectionNotifyFn.self)
    private static let registerGlobalNotify = symbol("SLSRegisterNotifyProc", as: RegisterGlobalNotifyFn.self)
        ?? symbol("CGSRegisterNotifyProc", as: RegisterGlobalNotifyFn.self)

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

    private static let connectionNotifyProc: ConnectionNotifyProc = { type, _, _, _, _ in
        DispatchQueue.main.async { SkyLight.onMissionControlEvent?(type) }
    }

    private static let globalNotifyProc: GlobalNotifyProc = { type, _, _, _ in
        DispatchQueue.main.async { SkyLight.onMissionControlEvent?(type) }
    }

    /// Mission Control 열림/닫힘 알림을 등록한다. 결과 문자열은 진단용.
    ///
    /// 등록 방식이 두 가지다. 연결마다 등록하는 것과 프로세스 전체에 등록하는 것.
    /// macOS 버전에 따라 한쪽만 실제로 알림을 보내 주므로 둘 다 등록한다.
    /// (연결 방식만 썼을 때 등록은 성공(0)했는데 알림이 한 번도 오지 않았다)
    /// 둘 다 오더라도 같은 값을 두 번 처리할 뿐이라 문제되지 않는다.
    static func registerMissionControlNotifications() -> String {
        var notes: [String] = []

        if let cid = connection, let fn = registerConnectionNotify {
            let codes = missionControlEvents.map { "\($0)=\(fn(cid, connectionNotifyProc, $0, nil))" }
            notes.append("연결별 " + codes.joined(separator: ","))
        } else {
            notes.append("연결별 등록 불가")
        }

        if let fn = registerGlobalNotify {
            let codes = missionControlEvents.map { "\($0)=\(fn(globalNotifyProc, $0, nil))" }
            notes.append("전체 " + codes.joined(separator: ","))
        } else {
            notes.append("전체 등록 불가 (심볼 없음)")
        }

        return notes.joined(separator: " / ")
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
