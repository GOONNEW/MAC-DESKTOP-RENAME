import Foundation
import Combine
import ServiceManagement

final class AppSettings: ObservableObject {
    private static let overlayKey = "overlayEnabled"

    @Published var overlayEnabled: Bool {
        didSet { UserDefaults.standard.set(overlayEnabled, forKey: Self.overlayKey) }
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
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
