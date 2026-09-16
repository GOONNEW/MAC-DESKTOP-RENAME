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

    /// 창이 속한 공간 ID 목록 (보통 1개, "모든 데스크탑" 창은 여러 개)
    static func spaceIDs(forWindow windowID: CGWindowID) -> [CGSSpaceID] {
        guard let cid = connection, let fn = copySpacesForWindows,
              let array = fn(cid, allSpacesMask, [NSNumber(value: windowID)] as CFArray)?.takeRetainedValue() else {
            return []
        }
        return ((array as NSArray) as? [NSNumber])?.map { $0.uint64Value } ?? []
    }
}
