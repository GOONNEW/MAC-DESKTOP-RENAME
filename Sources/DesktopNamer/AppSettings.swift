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
    private static let overlayWorksKey = "spacesBarOverlayWorks"

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

    /// 공간 막대 위에 이름을 덧그리는 방식이 이 맥에서 동작한 적이 있는가.
    ///
    /// 기억해 두면 다음에 켤 때부터 예전 배지를 아예 만들지 않는다.
    /// 배지를 준비하려면 데스크탑을 한 바퀴 돌아야 해서 화면이 어지럽게 바뀌는데,
    /// 덧그리기가 되면 그럴 필요가 없다.
    @Published var spacesBarOverlayWorks: Bool {
        didSet { UserDefaults.standard.set(spacesBarOverlayWorks, forKey: Self.overlayWorksKey) }
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
        spacesBarOverlayWorks = UserDefaults.standard.bool(forKey: Self.overlayWorksKey)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
