import AppKit
import Combine

/// 메뉴 막대 항목: 현재 공간 이름을 표시하고, 메뉴에서 공간 목록/이름 바꾸기/설정을 제공한다.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let spaces: SpaceManager
    private let names: NameStore
    private let settings: AppSettings
    private let onRename: () -> Void
    private let onRenameSpace: (Space) -> Void
    private let onSyncBadges: () -> Void
    private let onPreviewBadges: () -> Void
    private let onUpdate: () -> Void
    private let onDiagnose: () -> Void
    private let onRelearnGestures: () -> Void
    private let onCheckForUpdates: (Bool) -> Void
    /// 새 버전이 있는지 (있을 때만 업데이트 항목을 보여준다)
    private let updateAvailable: () -> Bool
    /// 마지막 확인 결과 (고급 메뉴에 그대로 보여준다)
    private let updateNote: () -> String

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()

    init(spaces: SpaceManager, names: NameStore, settings: AppSettings,
         onRename: @escaping () -> Void, onRenameSpace: @escaping (Space) -> Void,
         onSyncBadges: @escaping () -> Void, onPreviewBadges: @escaping () -> Void,
         onUpdate: @escaping () -> Void,
         onDiagnose: @escaping () -> Void,
         onRelearnGestures: @escaping () -> Void,
         onCheckForUpdates: @escaping (Bool) -> Void,
         updateAvailable: @escaping () -> Bool,
         updateNote: @escaping () -> String) {
        self.spaces = spaces
        self.names = names
        self.settings = settings
        self.onRename = onRename
        self.onRenameSpace = onRenameSpace
        self.onSyncBadges = onSyncBadges
        self.onPreviewBadges = onPreviewBadges
        self.onUpdate = onUpdate
        self.onDiagnose = onDiagnose
        self.onRelearnGestures = onRelearnGestures
        self.onCheckForUpdates = onCheckForUpdates
        self.updateAvailable = updateAvailable
        self.updateNote = updateNote
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        if let button = statusItem.button {
            button.image = Self.makeIcon()
            button.imagePosition = .imageLeading
        }

        spaces.$activeSpace
            .combineLatest(names.$names)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        if let active = spaces.activeSpace {
            button.title = " " + names.displayName(for: active)
        } else {
            button.title = ""
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // 오래됐으면 조용히 다시 확인한다 (결과는 다음에 메뉴를 열 때 반영된다)
        onCheckForUpdates(false)
        menu.removeAllItems()

        let header = NSMenuItem(title: "데스크탑", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        spaces.refreshApps()

        for space in spaces.spaces {
            let apps = spaces.apps(in: space)
            let item = NSMenuItem(title: "", action: #selector(switchSpace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = space
            item.state = space.isActive ? .on : .off
            item.isEnabled = space.number.map(SpaceSwitcher.canSwitch(to:)) ?? false
            item.image = WindowInspector.iconStrip(for: apps)

            var name = names.displayName(for: space)
            if space.isFullscreen, let app = apps.first {
                name = "전체 화면: \(app.name)"
            }
            item.attributedTitle = Self.attributedTitle(
                number: space.number,
                name: name,
                isDefault: names.customName(for: space) == nil,
                summary: WindowInspector.summary(for: apps)
            )
            menu.addItem(item)

            // ⌥ 키를 누르면 같은 자리에 "이름 바꾸기" 항목이 대신 보인다
            if !space.isFullscreen {
                let alternate = NSMenuItem(title: "이름 바꾸기: \(name)", action: #selector(renameSpace(_:)), keyEquivalent: "")
                alternate.target = self
                alternate.representedObject = space
                alternate.isAlternate = true
                alternate.keyEquivalentModifierMask = [.option]
                alternate.image = item.image
                menu.addItem(alternate)
            }
        }

        menu.addItem(.separator())

        let renameItem = NSMenuItem(title: "이름 편집…", action: #selector(rename(_:)), keyEquivalent: "r")
        renameItem.target = self
        menu.addItem(renameItem)

        let badge = NSMenuItem(title: "Mission Control에 이름 표시", action: #selector(toggleBadge(_:)), keyEquivalent: "")
        badge.target = self
        badge.state = settings.badgeEnabled ? .on : .off
        menu.addItem(badge)

        // 이름 표시 세부 설정은 하위 메뉴 하나로 묶는다
        let display = NSMenuItem(title: "표시 설정", action: nil, keyEquivalent: "")
        display.isEnabled = settings.badgeEnabled
        let displayMenu = NSMenu()
        displayMenu.autoenablesItems = false

        // 미션 컨트롤 위에 직접 그릴 수 있으면 준비할 것이 없다. 눌러도 하는 일이 없는
        // 항목은 두지 않는다. 그 방식이 안 되는 맥에서만 보인다.
        if !settings.spacesBarOverlayWorks {
            let sync = NSMenuItem(title: "데스크탑 이름 동기화…", action: #selector(syncBadges(_:)), keyEquivalent: "")
            sync.target = self
            displayMenu.addItem(sync)
            displayMenu.addItem(.separator())
        }

        let cornerItem = NSMenuItem(title: "위치", action: nil, keyEquivalent: "")
        let cornerMenu = NSMenu()
        cornerMenu.autoenablesItems = false
        // 미션 컨트롤 위에 직접 그릴 때는 가로를 썸네일 가운데로 고정하고, 세로만 고른다.
        // (버튼 영역이 실제 썸네일보다 넓어 한쪽에 붙이면 옆 썸네일로 밀려나고,
        //  접근성이 썸네일 그림만의 자리를 알려주지 않아 세로는 눈으로 맞추는 편이 확실하다)
        if settings.spacesBarOverlayWorks {
            for (index, title) in SpacesBarOverlay.stepTitles.enumerated() {
                let item = NSMenuItem(title: title, action: #selector(setOverlayStep(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = index
                item.state = settings.spacesBarOverlayStep == index ? .on : .off
                cornerMenu.addItem(item)
            }
        } else {
            for value in BadgeManager.Corner.allCases {
                let item = NSMenuItem(title: value.title, action: #selector(setCorner(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = value.rawValue
                item.state = settings.badgeCorner == value ? .on : .off
                cornerMenu.addItem(item)
            }
        }
        cornerItem.submenu = cornerMenu
        displayMenu.addItem(cornerItem)

        let sizeItem = NSMenuItem(title: "크기", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        sizeMenu.autoenablesItems = false
        for value in BadgeManager.Size.allCases {
            let item = NSMenuItem(title: value.title, action: #selector(setBadgeSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value.rawValue
            item.state = settings.badgeSize == value ? .on : .off
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        displayMenu.addItem(sizeItem)

        // 아래 항목들은 데스크탑 안쪽에 이름표 창을 두는 예전 방식에만 해당한다.
        // 미션 컨트롤 위에 직접 그리는 맥에서는 뜻이 없으므로 보이지 않는다.
        let usesBadges = !settings.spacesBarOverlayWorks

        if usesBadges, NSScreen.screens.count > 1 {
            let mainOnly = NSMenuItem(title: "주 화면에만 표시", action: #selector(toggleMainScreenOnly(_:)), keyEquivalent: "")
            mainOnly.target = self
            mainOnly.state = settings.badgeMainScreenOnly ? .on : .off
            displayMenu.addItem(mainOnly)

            let mirror = NSMenuItem(title: "보조 모니터에도 같은 이름 표시", action: #selector(toggleMirror(_:)), keyEquivalent: "")
            mirror.target = self
            mirror.state = settings.badgeMirrorToOtherScreens ? .on : .off
            mirror.isEnabled = settings.badgeMainScreenOnly
            displayMenu.addItem(mirror)
        }

        if usesBadges {
            displayMenu.addItem(.separator())

            let preview = NSMenuItem(title: "지금 이름 보기 (5초)", action: #selector(previewBadges(_:)), keyEquivalent: "")
            preview.target = self
            displayMenu.addItem(preview)

            let auto = NSMenuItem(title: "앱 시작 시 자동 준비", action: #selector(toggleAutoPrepare(_:)), keyEquivalent: "")
            auto.target = self
            auto.state = settings.badgeAutoPrepare ? .on : .off
            displayMenu.addItem(auto)
        }

        display.submenu = displayMenu
        menu.addItem(display)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = settings.launchAtLogin ? .on : .off
        menu.addItem(login)

        // 새 버전이 있을 때만 보여준다. 눈에 띄도록 직접 그린다.
        if updateAvailable() {
            let text = "최신 버전으로 업데이트하세요"
            let updateItem = NSMenuItem(title: text, action: #selector(update(_:)), keyEquivalent: "")
            updateItem.target = self
            updateItem.view = ShinyMenuItemView(title: text)
            menu.addItem(updateItem)
        }

        let advanced = NSMenuItem(title: "고급", action: nil, keyEquivalent: "")
        let advancedMenu = NSMenu()
        advancedMenu.autoenablesItems = false

        let resetTrackpad = NSMenuItem(title: "제스처·열림 감지 다시 익히기", action: #selector(resetTrackpad(_:)), keyEquivalent: "")
        resetTrackpad.target = self
        advancedMenu.addItem(resetTrackpad)

        let resetTrust = NSMenuItem(title: "접근성 권한 초기화 후 다시 요청", action: #selector(resetTrust(_:)), keyEquivalent: "")
        resetTrust.target = self
        advancedMenu.addItem(resetTrust)

        // 확인 결과를 그대로 보여준다. 안 보이면 "최신 버전"인지 "확인 실패"인지 알 수 없다.
        let updateState = NSMenuItem(title: updateNote(), action: nil, keyEquivalent: "")
        updateState.isEnabled = false
        advancedMenu.addItem(updateState)

        let checkUpdate = NSMenuItem(title: "업데이트 확인…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        checkUpdate.target = self
        advancedMenu.addItem(checkUpdate)

        let diagnose = NSMenuItem(title: "문제 진단…", action: #selector(diagnose(_:)), keyEquivalent: "")
        diagnose.target = self
        advancedMenu.addItem(diagnose)

        advanced.submenu = advancedMenu
        menu.addItem(advanced)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func switchSpace(_ sender: NSMenuItem) {
        guard let space = sender.representedObject as? Space else { return }
        spaces.switchTo(space)
    }

    @objc private func rename(_ sender: Any?) {
        onRename()
    }

    @objc private func renameSpace(_ sender: NSMenuItem) {
        guard let space = sender.representedObject as? Space else { return }
        onRenameSpace(space)
    }

    @objc private func resetTrackpad(_ sender: Any?) {
        TrackpadMonitor.resetLayout()
        onRelearnGestures()
        let alert = NSAlert()
        alert.messageText = "제스처·열림 감지 다시 익히기"
        alert.informativeText = "이제 세 손가락으로 위로 쓸어 Mission Control을 몇 번 열었다 닫아 주세요. 손가락 위치와 Mission Control이 열린 상태를 다시 배웁니다."
        alert.addButton(withTitle: "확인")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func resetTrust(_ sender: Any?) {
        let message = DockAccessibility.resetTrustAndRequest()
        let alert = NSAlert()
        alert.messageText = "접근성 권한"
        alert.informativeText = message + "\n\n시스템 설정 > 개인정보 보호 및 보안에서 DesktopNamer 스위치를 켠 뒤, 앱을 종료했다가 다시 실행하세요."
        alert.addButton(withTitle: "확인")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func diagnose(_ sender: Any?) {
        onDiagnose()
    }

    @objc private func toggleBadge(_ sender: Any?) {
        settings.badgeEnabled.toggle()
    }

    @objc private func setCorner(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let corner = BadgeManager.Corner(rawValue: raw) else { return }
        settings.badgeCorner = corner
    }

    @objc private func setOverlayStep(_ sender: NSMenuItem) {
        guard let step = sender.representedObject as? Int else { return }
        settings.spacesBarOverlayStep = step
    }

    @objc private func setBadgeSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let value = BadgeManager.Size(rawValue: raw) else { return }
        settings.badgeSize = value
    }

    @objc private func toggleMainScreenOnly(_ sender: Any?) {
        settings.badgeMainScreenOnly.toggle()
    }

    @objc private func toggleAutoPrepare(_ sender: Any?) {
        settings.badgeAutoPrepare.toggle()
    }

    @objc private func toggleMirror(_ sender: Any?) {
        settings.badgeMirrorToOtherScreens.toggle()
    }

    @objc private func syncBadges(_ sender: Any?) {
        onSyncBadges()
    }

    @objc private func update(_ sender: Any?) {
        onUpdate()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        onCheckForUpdates(true)
    }

    @objc private func previewBadges(_ sender: Any?) {
        onPreviewBadges()
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        settings.launchAtLogin.toggle()
    }

    // MARK: - Drawing helpers

    private static func attributedTitle(number: Int?, name: String, isDefault: Bool, summary: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.menuFont(ofSize: 0)
        let numberText = number.map { String($0) } ?? "—"
        result.append(NSAttributedString(string: numberText.padding(toLength: 3, withPad: " ", startingAt: 0), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        result.append(NSAttributedString(string: name, attributes: [
            .font: font,
            .foregroundColor: isDefault ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]))
        if !summary.isEmpty {
            result.append(NSAttributedString(string: "   " + summary, attributes: [
                .font: NSFont.menuFont(ofSize: font.pointSize - 2),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        return result
    }

    /// 2×2 격자 아이콘 (템플릿 이미지라 다크 모드에서도 자동 반전)
    private static func makeIcon() -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            let rects = [
                NSRect(x: 1.5, y: 9.5, width: 5, height: 4),
                NSRect(x: 9.5, y: 9.5, width: 5, height: 4),
                NSRect(x: 1.5, y: 2.5, width: 5, height: 4),
                NSRect(x: 9.5, y: 2.5, width: 5, height: 4),
            ]
            for rect in rects {
                let path = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
                path.lineWidth = 1.5
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
