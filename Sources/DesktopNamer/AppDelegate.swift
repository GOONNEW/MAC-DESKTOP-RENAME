import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let spaceManager = SpaceManager()
    private let nameStore = NameStore()
    private let settings = AppSettings()

    private var statusBar: StatusBarController?
    private var renameWindow: RenameWindowController?
    private var badges: BadgeManager?
    private let signals = MissionControlSignals()
    private var updater: Updater?
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

        renameWindow = RenameWindowController(spaces: spaceManager, names: nameStore)
        badges = BadgeManager(spaces: spaceManager, names: nameStore)
        signals.isShowing = { [weak self] in self?.badges?.isVisible ?? false }
        signals.onOpenLikely = { [weak self] reason in self?.badges?.show(reason: reason) }
        signals.onCloseLikely = { [weak self] reason in self?.badges?.hide(reason: reason) }
        signals.onStillOpen = { [weak self] in self?.badges?.keepAlive() }
        signals.start()
        statusBar = StatusBarController(
            spaces: spaceManager,
            names: nameStore,
            settings: settings,
            onRename: { [weak self] in self?.renameWindow?.show() },
            onRenameSpace: { [weak self] space in self?.promptRename(for: space) },
            onSyncBadges: { [weak self] in self?.syncBadges() },
            onPreviewBadges: { [weak self] in self?.badges?.preview() },
            onUpdate: { [weak self] in self?.startUpdate() },
            onDiagnose: { [weak self] in self?.showDiagnostics() },
            onRelearnGestures: { [weak self] in self?.signals.resetProbe() }
        )

        spaceManager.start()

        // 사라진 공간의 이름은 정리
        spaceManager.$spaces
            .map { $0.map(\.uuid) }
            .removeDuplicates()
            .sink { [weak self] uuids in self?.nameStore.prune(keeping: uuids) }
            .store(in: &cancellables)

        badges?.autoPrepare = settings.badgeAutoPrepare
        settings.$badgeAutoPrepare
            .sink { [weak self] auto in self?.badges?.autoPrepare = auto }
            .store(in: &cancellables)

        settings.$badgeEnabled
            .sink { [weak self] enabled in
                guard let self, let badges = self.badges else { return }
                enabled ? badges.start() : badges.stop()
            }
            .store(in: &cancellables)

        settings.$badgeCorner
            .sink { [weak self] corner in self?.badges?.corner = corner }
            .store(in: &cancellables)

        settings.$badgeSize
            .sink { [weak self] size in self?.badges?.size = size }
            .store(in: &cancellables)

        settings.$badgeMainScreenOnly
            .sink { [weak self] only in self?.badges?.mainScreenOnly = only }
            .store(in: &cancellables)

        settings.$badgeMirrorToOtherScreens
            .sink { [weak self] mirror in self?.badges?.mirrorToOtherScreens = mirror }
            .store(in: &cancellables)
    }

    /// 최신 코드를 받아 빌드하고 새 버전으로 재시작한다
    private func startUpdate() {
        let updater = Updater()
        self.updater = updater
        updater.start()
    }

    /// 데스크탑을 한 바퀴 돌며 이름표를 전부 새로 만든다.
    /// 이름이 안 보일 때 한 번 더 눌러도 되도록, 있는 것까지 싹 다시 만든다.
    private func syncBadges() {
        guard let badges else { return }
        badges.rebuildAllBadges { message in
            let alert = NSAlert()
            alert.messageText = "데스크탑 이름 동기화"
            alert.informativeText = message
            alert.addButton(withTitle: "확인")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// 데스크탑 하나의 이름을 묻는 작은 입력 창
    private func promptRename(for space: Space) {
        let alert = NSAlert()
        alert.messageText = "\(space.defaultName) 이름"
        alert.informativeText = "비워 두면 기본 이름(\(space.defaultName))으로 돌아갑니다."
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = space.defaultName
        field.stringValue = nameStore.customName(for: space) ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            nameStore.setName(field.stringValue, for: space)
        }
    }

    /// 진단 정보를 보여주고 클립보드로 복사할 수 있게 한다.
    private func showDiagnostics() {
        var text = badges?.diagnostics() ?? ""
        text += "\n\nMission Control 동작 감지\n  \(signals.note)\n  마지막 여는 동작: \(signals.lastOpenNote)"
        let alert = NSAlert()
        alert.messageText = "문제 진단"
        alert.informativeText = "아래 내용을 복사해서 보내주세요."
        alert.addButton(withTitle: "복사하고 닫기")
        alert.addButton(withTitle: "닫기")

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 320))
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = text
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 320))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        alert.accessoryView = scroll
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        badges?.stop()
        signals.stop()
        spaceManager.stop()
    }
}
