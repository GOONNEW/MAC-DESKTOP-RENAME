import Foundation
import Combine
import ServiceManagement

final class AppSettings: ObservableObject {
    private static let overlayKey = "overlayEnabled"
    private static let alwaysWatchKey = "alwaysWatch"
    private static let badgeKey = "badgeEnabled"
    private static let badgeCornerKey = "badgeCorner"
    private static let badgeSizeKey = "badgeSize"
    private static let badgeMainOnlyKey = "badgeMainScreenOnly"

    @Published var overlayEnabled: Bool {
        didSet { UserDefaults.standard.set(overlayEnabled, forKey: Self.overlayKey) }
    }

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

    /// 화면 감시를 항상 켠다 (가장 빠르지만 메뉴 막대에 화면 기록 표시가 계속 뜬다)
    @Published var alwaysWatch: Bool {
        didSet { UserDefaults.standard.set(alwaysWatch, forKey: Self.alwaysWatchKey) }
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
        overlayEnabled = UserDefaults.standard.bool(forKey: Self.overlayKey)
        alwaysWatch = UserDefaults.standard.bool(forKey: Self.alwaysWatchKey)
        // 배지는 기본으로 켠다 (한 번도 설정한 적 없으면 true)
        badgeEnabled = UserDefaults.standard.object(forKey: Self.badgeKey) as? Bool ?? true
        badgeCorner = (UserDefaults.standard.string(forKey: Self.badgeCornerKey)).flatMap(BadgeManager.Corner.init(rawValue:)) ?? .bottomRight
        badgeSize = (UserDefaults.standard.string(forKey: Self.badgeSizeKey)).flatMap(BadgeManager.Size.init(rawValue:)) ?? .large
        badgeMainScreenOnly = UserDefaults.standard.bool(forKey: Self.badgeMainOnlyKey)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
