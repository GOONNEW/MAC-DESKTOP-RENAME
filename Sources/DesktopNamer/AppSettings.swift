import Foundation
import Combine
import ServiceManagement

final class AppSettings: ObservableObject {
    private static let overlayKey = "overlayEnabled"
    private static let alwaysWatchKey = "alwaysWatch"

    @Published var overlayEnabled: Bool {
        didSet { UserDefaults.standard.set(overlayEnabled, forKey: Self.overlayKey) }
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
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
