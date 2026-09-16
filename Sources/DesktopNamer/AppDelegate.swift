import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let spaceManager = SpaceManager()
    private let nameStore = NameStore()
    private let settings = AppSettings()

    private var statusBar: StatusBarController?
    private var renameWindow: RenameWindowController?
    private var overlay: MissionControlOverlay?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SkyLight.isAvailable else {
            let alert = NSAlert()
            alert.messageText = "이 macOS 버전에서는 데스크탑 정보를 읽을 수 없습니다."
            alert.informativeText = "SkyLight 프레임워크의 공간(Space) API를 찾지 못했습니다."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        renameWindow = RenameWindowController(spaces: spaceManager, names: nameStore, settings: settings)
        overlay = MissionControlOverlay(spaces: spaceManager, names: nameStore)
        statusBar = StatusBarController(
            spaces: spaceManager,
            names: nameStore,
            settings: settings,
            onRename: { [weak self] in self?.renameWindow?.show() }
        )

        spaceManager.start()

        // 사라진 공간의 이름은 정리
        spaceManager.$spaces
            .map { $0.map(\.uuid) }
            .removeDuplicates()
            .sink { [weak self] uuids in self?.nameStore.prune(keeping: uuids) }
            .store(in: &cancellables)

        // 오버레이 설정 반영
        settings.$overlayEnabled
            .sink { [weak self] enabled in
                guard let overlay = self?.overlay else { return }
                enabled ? overlay.start() : overlay.stop()
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay?.stop()
        spaceManager.stop()
    }
}
