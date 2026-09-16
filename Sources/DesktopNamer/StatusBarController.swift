import AppKit
import Combine

/// 메뉴 막대 항목: 현재 공간 이름을 표시하고, 메뉴에서 공간 목록/이름 바꾸기/설정을 제공한다.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let spaces: SpaceManager
    private let names: NameStore
    private let settings: AppSettings
    private let onRename: () -> Void
    private let onRenameSpace: (Space) -> Void
    private let onPrepareBadges: () -> Void
    private let onPreviewBadges: () -> Void
    private let onUpdate: () -> Void
    private let onDiagnose: () -> Void

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()

    init(spaces: SpaceManager, names: NameStore, settings: AppSettings,
         onRename: @escaping () -> Void, onRenameSpace: @escaping (Space) -> Void,
         onPrepareBadges: @escaping () -> Void, onPreviewBadges: @escaping () -> Void,
         onUpdate: @escaping () -> Void,
         onDiagnose: @escaping () -> Void) {
        self.spaces = spaces
        self.names = names
        self.settings = settings
        self.onRename = onRename
        self.onRenameSpace = onRenameSpace
        self.onPrepareBadges = onPrepareBadges
        self.onPreviewBadges = onPreviewBadges
        self.onUpdate = onUpdate
        self.onDiagnose = onDiagnose
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

        let rename = NSMenuItem(title: "이름 바꾸기", action: nil, keyEquivalent: "")
        let renameMenu = NSMenu()
        renameMenu.autoenablesItems = false
        let editAll = NSMenuItem(title: "모두 편집…", action: #selector(rename(_:)), keyEquivalent: "r")
        editAll.target = self
        renameMenu.addItem(editAll)
        renameMenu.addItem(.separator())
        for space in spaces.spaces where !space.isFullscreen {
            let item = NSMenuItem(title: "\(space.number.map { String($0) } ?? "") \(names.displayName(for: space))", action: #selector(renameSpace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = space
            renameMenu.addItem(item)
        }
        rename.submenu = renameMenu
        menu.addItem(rename)

        let badge = NSMenuItem(title: "Mission Control에 이름 표시", action: #selector(toggleBadge(_:)), keyEquivalent: "")
        badge.target = self
        badge.state = settings.badgeEnabled ? .on : .off
        menu.addItem(badge)

        // 이름 표시 세부 설정은 하위 메뉴 하나로 묶는다
        let display = NSMenuItem(title: "표시 설정", action: nil, keyEquivalent: "")
        display.isEnabled = settings.badgeEnabled
        let displayMenu = NSMenu()
        displayMenu.autoenablesItems = false

        let cornerItem = NSMenuItem(title: "위치", action: nil, keyEquivalent: "")
        let cornerMenu = NSMenu()
        cornerMenu.autoenablesItems = false
        for value in BadgeManager.Corner.allCases {
            let item = NSMenuItem(title: value.title, action: #selector(setCorner(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value.rawValue
            item.state = settings.badgeCorner == value ? .on : .off
            cornerMenu.addItem(item)
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

        if NSScreen.screens.count > 1 {
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

        displayMenu.addItem(.separator())

        let preview = NSMenuItem(title: "지금 이름 보기 (5초)", action: #selector(previewBadges(_:)), keyEquivalent: "")
        preview.target = self
        displayMenu.addItem(preview)

        let prepare = NSMenuItem(title: "모든 데스크탑에 이름 준비…", action: #selector(prepareBadges(_:)), keyEquivalent: "")
        prepare.target = self
        displayMenu.addItem(prepare)

        display.submenu = displayMenu
        menu.addItem(display)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = settings.launchAtLogin ? .on : .off
        menu.addItem(login)

        if Updater.canUpdate {
            let update = NSMenuItem(title: "최신 버전으로 업데이트…", action: #selector(update(_:)), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
        }

        let advanced = NSMenuItem(title: "고급", action: nil, keyEquivalent: "")
        let advancedMenu = NSMenu()
        advancedMenu.autoenablesItems = false

        let overlay = NSMenuItem(title: "실험: 화면을 읽어 라벨 덮어쓰기", action: #selector(toggleOverlay(_:)), keyEquivalent: "")
        overlay.target = self
        overlay.state = settings.overlayEnabled ? .on : .off
        advancedMenu.addItem(overlay)

        let always = NSMenuItem(title: "화면 항상 감시 (화면 기록 표시가 계속 뜸)", action: #selector(toggleAlwaysWatch(_:)), keyEquivalent: "")
        always.target = self
        always.state = settings.alwaysWatch ? .on : .off
        always.isEnabled = settings.overlayEnabled
        advancedMenu.addItem(always)

        advancedMenu.addItem(.separator())

        let resetTrackpad = NSMenuItem(title: "트랙패드 제스처 다시 인식", action: #selector(resetTrackpad(_:)), keyEquivalent: "")
        resetTrackpad.target = self
        advancedMenu.addItem(resetTrackpad)

        let resetTrust = NSMenuItem(title: "접근성 권한 초기화 후 다시 요청", action: #selector(resetTrust(_:)), keyEquivalent: "")
        resetTrust.target = self
        advancedMenu.addItem(resetTrust)

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
        let alert = NSAlert()
        alert.messageText = "트랙패드 제스처 다시 인식"
        alert.informativeText = "이제 트랙패드에 세 손가락을 얹고 위아래로 몇 번 움직여 주세요. 손가락 위치를 다시 찾습니다."
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

    @objc private func setBadgeSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let value = BadgeManager.Size(rawValue: raw) else { return }
        settings.badgeSize = value
    }

    @objc private func toggleMainScreenOnly(_ sender: Any?) {
        settings.badgeMainScreenOnly.toggle()
    }

    @objc private func toggleMirror(_ sender: Any?) {
        settings.badgeMirrorToOtherScreens.toggle()
    }

    @objc private func prepareBadges(_ sender: Any?) {
        onPrepareBadges()
    }

    @objc private func update(_ sender: Any?) {
        onUpdate()
    }

    @objc private func previewBadges(_ sender: Any?) {
        onPreviewBadges()
    }

    @objc private func toggleOverlay(_ sender: Any?) {
        settings.overlayEnabled.toggle()
    }

    @objc private func toggleAlwaysWatch(_ sender: Any?) {
        settings.alwaysWatch.toggle()
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
