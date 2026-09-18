import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let spaceManager = SpaceManager()
    private let nameStore = NameStore()
    private let settings = AppSettings()

    private var statusBar: StatusBarController?
    private var renameWindow: RenameWindowController?
    private var badges: BadgeManager?
    private var barOverlay: SpacesBarOverlay?
    private let signals = MissionControlSignals()
    private var updater: Updater?
    private let updateChecker = UpdateChecker()
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
        barOverlay = SpacesBarOverlay(spaces: spaceManager, names: nameStore)
        // 공간 막대 위에 이름을 올릴 수 있으면, 데스크탑 안쪽에 두던 예전 배지는 끈다.
        // 둘 다 켜져 있으면 미션 컨트롤에 같은 이름이 두 번 보인다.
        barOverlay?.onPlaced = { [weak self] in
            guard let self else { return }
            self.badges?.suppressed = true
            if !self.settings.spacesBarOverlayWorks { self.settings.spacesBarOverlayWorks = true }
        }
        // 지난번에 덧그리기가 동작했다면 이번에도 배지는 만들지 않는다.
        // 배지를 준비하려면 데스크탑을 한 바퀴 돌아야 해서 화면이 어지럽게 바뀐다.
        badges?.suppressed = settings.spacesBarOverlayWorks
        // "지금 이름이 보이는 중인가"는 둘 중 하나라도 보이면 참이다.
        // 배지만 보면, 배지를 끈 뒤에는 늘 거짓이 되어 닫힘 판단과 위치 갱신이 통째로 멈춘다.
        signals.isShowing = { [weak self] in
            guard let self else { return false }
            return self.badges?.isVisible == true || self.barOverlay?.isShowing == true
        }
        signals.onOpenLikely = { [weak self] reason in
            self?.badges?.show(reason: reason)
            // 공간 막대가 그려질 시간을 조금 준 뒤 그 위에 이름을 덧그린다
            for delay in [0.25, 0.45, 0.7] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.barOverlay?.update() }
            }
        }
        signals.onCloseLikely = { [weak self] reason, force in
            self?.badges?.hide(reason: reason, force: force)
            self?.barOverlay?.hide()
        }
        signals.onStillOpen = { [weak self] in self?.badges?.keepAlive() }
        signals.onTick = { [weak self] in self?.barOverlay?.update() }
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
            onRelearnGestures: { [weak self] in self?.signals.resetProbe() },
            onCheckForUpdates: { [weak self] show in self?.checkForUpdates(showResult: show) },
            updateAvailable: { [weak self] in self?.updateChecker.updateAvailable ?? false },
            updateNote: { [weak self] in self?.updateChecker.note ?? "확인 전" }
        )

        // 새 버전이 나오면 메뉴에 표시한다. 켠 직후와 10분마다 확인한다.
        // 확인은 비동기라서, 메뉴를 열 때 확인을 시작하면 결과가 그 메뉴에는 못 담긴다.
        // 그래서 평소에 미리 확인해 두어야 메뉴를 처음 열 때 바로 보인다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.updateChecker.check()
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            self?.updateChecker.check()
        }

        spaceManager.start()

        // 사라진 공간의 이름은 정리
        spaceManager.$spaces
            .map { $0.map(\.uuid) }
            .removeDuplicates()
            .sink { [weak self] uuids in self?.nameStore.prune(keeping: uuids) }
            .store(in: &cancellables)

        badges?.autoPrepare = settings.badgeAutoPrepare && !settings.spacesBarOverlayWorks
        settings.$badgeAutoPrepare
            .sink { [weak self] auto in self?.badges?.autoPrepare = auto }
            .store(in: &cancellables)

        settings.$badgeEnabled
            .sink { [weak self] enabled in
                guard let self, let badges = self.badges else { return }
                enabled ? badges.start() : badges.stop()
                enabled ? self.barOverlay?.start() : self.barOverlay?.stop()
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

    private var updateTimer: Timer?

    /// - Parameter showResult: true면 결과를 알림창으로 보여준다 (메뉴에서 직접 누른 경우)
    private func checkForUpdates(showResult: Bool) {
        guard showResult else {
            updateChecker.checkIfStale()
            return
        }
        updateChecker.check { [weak self] available in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = available ? "새 버전이 있습니다" : "최신 버전입니다"
            var text = self.updateChecker.note
            if available, let title = self.updateChecker.latestCommitTitle {
                text += "\n\n새 내용: \(title)"
            }
            alert.informativeText = text
            if available {
                alert.addButton(withTitle: "지금 업데이트")
                alert.addButton(withTitle: "나중에")
            } else {
                alert.addButton(withTitle: "확인")
            }
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn, available {
                self.startUpdate()
            }
        }
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
        text += "\n\n\(barOverlay?.diagnostics ?? "공간 막대 덧그리기: 없음")"
        if let snapshot = SpacesBarAX.lastOpenSnapshot {
            text += "\n\n공간 막대 (Mission Control이 열렸을 때 본 모습):\n" + snapshot
        } else {
            text += "\n\n공간 막대: 아직 열린 상태를 본 적이 없습니다."
                + "\n미션 컨트롤을 한 번 연 뒤 다시 진단해 주세요."
                + "\n지금 트리:\n" + SpacesBarAX.treeDump(maxLines: 30)
        }
        text += "\n\n업데이트: \(updateChecker.note)"
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
        updateTimer?.invalidate()
        badges?.stop()
        barOverlay?.stop()
        signals.stop()
        spaceManager.stop()
    }
}
