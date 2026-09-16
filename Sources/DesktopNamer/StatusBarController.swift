import AppKit
import Combine

/// 메뉴 막대 항목: 현재 공간 이름을 표시하고, 메뉴에서 공간 목록/이름 바꾸기/설정을 제공한다.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let spaces: SpaceManager
    private let names: NameStore
    private let settings: AppSettings
    private let onRename: () -> Void
    private let onRenameSpace: (Space) -> Void
    private let onDiagnose: () -> Void
    private let onVisibilityTest: () -> Void

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()

    init(spaces: SpaceManager, names: NameStore, settings: AppSettings,
         onRename: @escaping () -> Void, onRenameSpace: @escaping (Space) -> Void,
         onDiagnose: @escaping () -> Void, onVisibilityTest: @escaping () -> Void) {
        self.spaces = spaces
        self.names = names
        self.settings = settings
        self.onRename = onRename
        self.onRenameSpace = onRenameSpace
        self.onDiagnose = onDiagnose
        self.onVisibilityTest = onVisibilityTest
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

        let overlay = NSMenuItem(title: "Mission Control에 이름 겹쳐 보이기", action: #selector(toggleOverlay(_:)), keyEquivalent: "")
        overlay.target = self
        overlay.state = settings.overlayEnabled ? .on : .off
        menu.addItem(overlay)

        let always = NSMenuItem(title: "화면 항상 감시 (더 빠름, 화면 기록 표시가 계속 뜸)", action: #selector(toggleAlwaysWatch(_:)), keyEquivalent: "")
        always.target = self
        always.state = settings.alwaysWatch ? .on : .off
        always.isEnabled = settings.overlayEnabled
        always.indentationLevel = 1
        menu.addItem(always)

        let login = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = settings.launchAtLogin ? .on : .off
        menu.addItem(login)

        let resetTrust = NSMenuItem(title: "접근성 권한 초기화 후 다시 요청", action: #selector(resetTrust(_:)), keyEquivalent: "")
        resetTrust.target = self
        menu.addItem(resetTrust)

        let test = NSMenuItem(title: "오버레이 표시 테스트 (15초)", action: #selector(visibilityTest(_:)), keyEquivalent: "")
        test.target = self
        menu.addItem(test)

        let diagnose = NSMenuItem(title: "문제 진단…", action: #selector(diagnose(_:)), keyEquivalent: "")
        diagnose.target = self
        menu.addItem(diagnose)

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

    @objc private func resetTrust(_ sender: Any?) {
        let message = DockAccessibility.resetTrustAndRequest()
        let alert = NSAlert()
        alert.messageText = "접근성 권한"
        alert.informativeText = message + "\n\n시스템 설정 > 개인정보 보호 및 보안에서 DesktopNamer 스위치를 켠 뒤, 앱을 종료했다가 다시 실행하세요."
        alert.addButton(withTitle: "확인")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func visibilityTest(_ sender: Any?) {
        onVisibilityTest()
    }

    @objc private func diagnose(_ sender: Any?) {
        onDiagnose()
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
