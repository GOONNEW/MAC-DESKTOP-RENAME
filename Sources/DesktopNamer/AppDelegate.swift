import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let spaceManager = SpaceManager()
    private let nameStore = NameStore()
    private let settings = AppSettings()

    private var statusBar: StatusBarController?
    private var renameWindow: RenameWindowController?
    private var overlay: MissionControlOverlay?
    private var badges: BadgeManager?
    private let signals = MissionControlSignals()
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
        badges = BadgeManager(spaces: spaceManager, names: nameStore)
        signals.isShowing = { [weak self] in self?.badges?.isVisible ?? false }
        signals.onOpenLikely = { [weak self] reason in
            self?.badges?.show(reason: reason)
            self?.overlay?.noteOpenLikely(reason: reason)
        }
        signals.onCloseLikely = { [weak self] reason in
            self?.badges?.hide(reason: reason)
            self?.overlay?.noteCloseLikely(reason: reason)
        }
        signals.start()
        statusBar = StatusBarController(
            spaces: spaceManager,
            names: nameStore,
            settings: settings,
            onRename: { [weak self] in self?.renameWindow?.show() },
            onRenameSpace: { [weak self] space in self?.promptRename(for: space) },
            onPrepareBadges: { [weak self] in self?.prepareBadges() },
            onPreviewBadges: { [weak self] in self?.badges?.preview() },
            onUpdate: { [weak self] in self?.startUpdate() },
            onDiagnose: { [weak self] in self?.showDiagnostics() }
        )

        spaceManager.start()

        // 사라진 공간의 이름은 정리
        spaceManager.$spaces
            .map { $0.map(\.uuid) }
            .removeDuplicates()
            .sink { [weak self] uuids in self?.nameStore.prune(keeping: uuids) }
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

        settings.$alwaysWatch
            .sink { [weak self] always in self?.overlay?.alwaysWatch = always }
            .store(in: &cancellables)

        // 오버레이 설정 반영
        settings.$overlayEnabled
            .sink { [weak self] enabled in
                guard let self, let overlay = self.overlay else { return }
                _ = self
                enabled ? overlay.start() : overlay.stop()
            }
            .store(in: &cancellables)
    }

    /// 최신 코드를 받아 빌드하고 새 버전으로 재시작한다
    private func startUpdate() {
        let alert = NSAlert()
        alert.messageText = "최신 버전으로 업데이트"
        alert.informativeText = "최신 코드를 내려받아 빌드한 뒤 앱을 다시 시작합니다.\n터미널 창이 열려 진행 상황이 보이고, 1~3분 걸립니다."
        alert.addButton(withTitle: "업데이트")
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let error = Updater.runUpdate() {
            let failure = NSAlert()
            failure.messageText = "업데이트를 시작하지 못했습니다"
            failure.informativeText = error
            failure.addButton(withTitle: "확인")
            failure.runModal()
            return
        }
        // 터미널 스크립트가 앱 종료를 기다린 뒤 빌드한다
        NSApp.terminate(nil)
    }

    /// 배지가 없는 데스크탑을 돌며 배지를 만든다
    private func prepareBadges() {
        guard let badges else { return }
        badges.prepareAllBadges { message in
            let alert = NSAlert()
            alert.messageText = "모든 데스크탑에 배지 준비"
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
        guard let overlay else { return }
        var text = badges?.diagnostics() ?? ""
        text += "\nMission Control 동작 감지: \(signals.note), 마지막: \(signals.lastOpenNote)\n\n"
        text += overlay.diagnostics()
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
        overlay?.stop()
        badges?.stop()
        signals.stop()
        spaceManager.stop()
    }
}
