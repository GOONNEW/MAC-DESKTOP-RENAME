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
            onRename: { [weak self] in self?.renameWindow?.show() },
            onDiagnose: { [weak self] in self?.showDiagnostics() },
            onVisibilityTest: { [weak self] in self?.overlay?.runVisibilityTest() }
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

    /// 진단 정보를 보여주고 클립보드로 복사할 수 있게 한다.
    private func showDiagnostics() {
        guard let overlay else { return }
        let text = overlay.diagnostics()
        let alert = NSAlert()
        alert.messageText = "문제 진단"
        alert.informativeText = "Mission Control을 2초쯤 열었다가 닫은 뒤 이 창을 열면 감지 결과가 채워집니다.\n\n" + text
        alert.addButton(withTitle: "복사하고 닫기")
        alert.addButton(withTitle: "닫기")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay?.stop()
        spaceManager.stop()
    }
}
