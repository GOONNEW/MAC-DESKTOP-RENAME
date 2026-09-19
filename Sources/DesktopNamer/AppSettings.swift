import Foundation
import Combine
import ServiceManagement

final class AppSettings: ObservableObject {
    private static let badgeKey = "badgeEnabled"
    private static let badgeCornerKey = "badgeCorner"
    private static let badgeSizeKey = "badgeSize"
    private static let badgeMainOnlyKey = "badgeMainScreenOnly"
    private static let badgeMirrorKey = "badgeMirrorToOtherScreens"
    private static let badgeAutoPrepareKey = "badgeAutoPrepare"
    // 키 이름을 바꿔 예전에 저장된 값을 버린다. 기본값이 "켬"이던 시절의 설정이 남아 있으면
    // 업데이트해도 이름표가 하나 더 따라 나온다.
    private static let overlayStepKey = "spacesBarOverlayStep2"

    /// 데스크탑마다 이름 배지 창을 두고 Mission Control이 열릴 때만 보이게 한다 (기본 방식)
    @Published var badgeEnabled: Bool {
        didSet { UserDefaults.standard.set(badgeEnabled, forKey: Self.badgeKey) }
    }

    @Published var badgeCorner: BadgeManager.Corner {
        didSet { UserDefaults.standard.set(badgeCorner.rawValue, forKey: Self.badgeCornerKey) }
    }

    @Published var badgeSize: BadgeManager.Size {
        didSet { UserDefaults.standard.set(badgeSize.rawValue, forKey: Self.badgeSizeKey) }
    }

    /// 듀얼 모니터에서 주 화면에만 이름을 표시한다
    @Published var badgeMainScreenOnly: Bool {
        didSet { UserDefaults.standard.set(badgeMainScreenOnly, forKey: Self.badgeMainOnlyKey) }
    }

    /// 보조 모니터에도 현재 데스크탑 이름을 함께 표시한다
    @Published var badgeMirrorToOtherScreens: Bool {
        didSet { UserDefaults.standard.set(badgeMirrorToOtherScreens, forKey: Self.badgeMirrorKey) }
    }

    /// 앱을 켤 때 모든 데스크탑에 이름을 자동으로 준비한다
    @Published var badgeAutoPrepare: Bool {
        didSet { UserDefaults.standard.set(badgeAutoPrepare, forKey: Self.badgeAutoPrepareKey) }
    }

    /// 현재 데스크탑 이름을 미션 컨트롤 위에 덧그릴지와 그 세로 단계
    /// (-1 = 끔, 0 = 맨 위 … 4 = 맨 아래)
    ///
    /// 기본은 끔이다. 데스크탑 안쪽에 둔 이름표가 현재 데스크탑 썸네일에도 대체로 잘 담기고,
    /// 덧그리면 이름표가 하나 더 따라 나온다. 접근성이 알려주는 버튼 영역이 눈에 보이는
    /// 공간 막대보다 아래로 넓어서, 그 안에 놓아도 막대 밖에 뜬다.
    /// 현재 데스크탑 이름이 자주 빠지는 사람만 켜면 된다.
    @Published var spacesBarOverlayStep: Int {
        didSet { UserDefaults.standard.set(spacesBarOverlayStep, forKey: Self.overlayStepKey) }
    }

    private var isReverting = false

    @Published var launchAtLogin: Bool {
        didSet {
            guard !isReverting, launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("로그인 시 자동 실행 설정 실패: \(error)")
                isReverting = true
                launchAtLogin = oldValue
                isReverting = false
            }
        }
    }

    init() {
        // 배지는 기본으로 켠다 (한 번도 설정한 적 없으면 true)
        badgeEnabled = UserDefaults.standard.object(forKey: Self.badgeKey) as? Bool ?? true
        badgeCorner = (UserDefaults.standard.string(forKey: Self.badgeCornerKey)).flatMap(BadgeManager.Corner.init(rawValue:)) ?? .bottomRight
        badgeSize = (UserDefaults.standard.string(forKey: Self.badgeSizeKey)).flatMap(BadgeManager.Size.init(rawValue:)) ?? .large
        // 보조 모니터는 데스크탑이 하나뿐인 경우가 많아 배지가 쌓인다. 기본은 주 화면만.
        badgeMainScreenOnly = UserDefaults.standard.object(forKey: Self.badgeMainOnlyKey) as? Bool ?? true
        badgeMirrorToOtherScreens = UserDefaults.standard.bool(forKey: Self.badgeMirrorKey)
        badgeAutoPrepare = UserDefaults.standard.object(forKey: Self.badgeAutoPrepareKey) as? Bool ?? true
        spacesBarOverlayStep = UserDefaults.standard.object(forKey: Self.overlayStepKey) as? Int ?? -1
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
