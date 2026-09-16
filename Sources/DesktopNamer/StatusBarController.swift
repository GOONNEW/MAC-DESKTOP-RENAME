import AppKit
import Combine

/// 메뉴 막대 항목: 현재 공간 이름을 표시하고, 메뉴에서 공간 목록/이름 바꾸기/설정을 제공한다.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let spaces: SpaceManager
    private let names: NameStore
    private let settings: AppSettings
    private let onRename: () -> Void

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()

    init(spaces: SpaceManager, names: NameStore, settings: AppSettings, onRename: @escaping () -> Void) {
        self.spaces = spaces
        self.names = names
        self.settings = settings
        self.onRename = onRename
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.delegate = self
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

        for space in spaces.spaces {
            let item = NSMenuItem(title: "", action: #selector(switchSpace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = space
            item.state = space.isActive ? .on : .off
            item.attributedTitle = Self.attributedTitle(
                number: space.number,
                name: names.displayName(for: space),
                isDefault: names.customName(for: space) == nil
            )
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let rename = NSMenuItem(title: "이름 바꾸기…", action: #selector(rename(_:)), keyEquivalent: "r")
        rename.target = self
        menu.addItem(rename)

        let overlay = NSMenuItem(title: "Mission Control에 이름 겹쳐 보이기", action: #selector(toggleOverlay(_:)), keyEquivalent: "")
        overlay.target = self
        overlay.state = settings.overlayEnabled ? .on : .off
        menu.addItem(overlay)

        let login = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = settings.launchAtLogin ? .on : .off
        menu.addItem(login)

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

    @objc private func toggleOverlay(_ sender: Any?) {
        settings.overlayEnabled.toggle()
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        settings.launchAtLogin.toggle()
    }

    // MARK: - Drawing helpers

    private static func attributedTitle(number: Int?, name: String, isDefault: Bool) -> NSAttributedString {
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
