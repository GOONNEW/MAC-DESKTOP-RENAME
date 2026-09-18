import AppKit

/// Mission Control의 공간 막대 위에, 각 데스크탑 썸네일 자리에 이름표를 덧그린다.
///
/// 기존 "배지" 방식은 이름표 창을 각 데스크탑 **안에** 두고, Mission Control이 그 데스크탑을
/// 축소해 그릴 때 같이 찍히길 기대한다. 다른 데스크탑에는 잘 되지만, **지금 보고 있는**
/// 데스크탑만은 안 된다. macOS가 Mission Control을 열면서 현재 화면을 한 번 찍어 쓰는데,
/// 그 순간은 우리가 이름표를 띄우기 전이기 때문이다. 아무리 빨리 띄워도 이기기 어려운 경합이다.
///
/// 이 방식은 Mission Control **위에** 그린다. 그래서 언제 찍혔는지와 상관이 없고,
/// 지금 보고 있는 데스크탑에도 똑같이 나온다.
final class SpacesBarOverlay {
    private let spaces: SpaceManager
    private let names: NameStore

    private var panels: [NSPanel] = []
    private var fields: [NSTextField] = []
    private var running = false
    private(set) var lastNote = "시작 안 됨"
    private(set) var isShowing = false
    /// 한 번이라도 이름표를 제대로 올린 적이 있는가.
    /// 이게 true면 데스크탑 안쪽에 두는 예전 배지는 필요 없다.
    private(set) var everWorked = false
    /// 이름표를 올릴 때마다 호출된다 (예전 배지를 끄기 위함)
    var onPlaced: (() -> Void)?

    init(spaces: SpaceManager, names: NameStore) {
        self.spaces = spaces
        self.names = names
    }

    func start() {
        running = true
    }

    func stop() {
        running = false
        hide()
    }

    /// Mission Control이 열려 있는 동안 자주 불러 위치를 맞춘다.
    func update() {
        guard running else { return }
        let scan = SpacesBarAX.scan()
        lastNote = "\(scan.source): \(scan.note)"
        guard !scan.buttons.isEmpty else {
            hide()
            return
        }

        // 공간 막대의 버튼은 왼쪽부터 차례대로다. 이름을 붙일 것만 골라 짝지운다.
        let labels = matchNames(to: scan.buttons)
        guard !labels.isEmpty else {
            hide()
            return
        }

        ensurePanels(count: labels.count)
        for (index, item) in labels.enumerated() {
            place(panel: panels[index], field: fields[index], text: item.name, over: item.frame)
        }
        for extra in labels.count..<panels.count {
            panels[extra].alphaValue = 0
        }
        isShowing = true
        everWorked = true
        onPlaced?()
    }

    func hide() {
        guard isShowing || !panels.isEmpty else { return }
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        fields.removeAll()
        isShowing = false
    }

    // MARK: - 이름 짝짓기

    private struct Placement {
        let frame: CGRect
        let name: String
    }

    /// 공간 막대의 버튼과 우리가 아는 데스크탑을 짝지운다.
    ///
    /// 버튼 설명은 이름을 바꾸기 전 기본 이름("데스크탑 3")이거나 전체 화면 앱 이름이다.
    /// 끝의 숫자를 데스크탑 번호로 보고 맞춘다. 숫자가 없으면 전체 화면 공간이라 건너뛴다.
    private func matchNames(to buttons: [SpacesBarAX.SpaceButton]) -> [Placement] {
        var result: [Placement] = []
        for button in buttons {
            guard let number = button.number,
                  let space = spaces.spaces.first(where: { $0.number == number && !$0.isFullscreen }),
                  let name = names.customName(for: space) else { continue }
            result.append(Placement(frame: button.frame, name: name))
        }
        return result
    }

    // MARK: - 창

    private func ensurePanels(count: Int) {
        while panels.count < count {
            let (panel, field) = makePanel()
            panels.append(panel)
            fields.append(field)
        }
    }

    private func makePanel() -> (NSPanel, NSTextField) {
        let field = NSTextField(labelWithString: "")
        field.textColor = .white
        field.alignment = .center
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1

        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: 0.88).cgColor

        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        // Mission Control 자체보다 위에 그려야 한다. 보조 기술이 쓰는 가장 높은 단계.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        // Mission Control은 모든 공간 위에 뜨므로 이름표도 따라다녀야 한다
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = container
        container.addSubview(field)
        return (panel, field)
    }

    /// 공간 버튼 안에서 "썸네일 그림"이 차지하는 부분만 골라낸다.
    ///
    /// 접근성이 알려주는 버튼 영역에는 썸네일 그림뿐 아니라 그 아래의 "데스크탑 N" 글자와
    /// 여백까지 들어 있다. 버튼 아래쪽에 맞춰 놓았더니 이름표가 공간 막대 바깥,
    /// 화면 한가운데에 떠 버렸다.
    /// 썸네일 그림은 화면과 같은 비율로 축소된 것이므로, 너비에 화면 비율을 곱하면 높이가 나온다.
    /// 비율 추정이 빗나가도 버튼 밖으로 나가지 않도록 위아래로 묶어 둔다.
    private func thumbnailRect(in button: CGRect) -> CGRect {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(button) })
            ?? NSScreen.screens.first
        let ratio = screen.map { $0.frame.height / $0.frame.width } ?? 0.625
        let estimated = button.width * ratio
        let height = min(max(estimated, button.height * 0.4), button.height * 0.85)
        return CGRect(x: button.minX, y: button.maxY - height, width: button.width, height: height)
    }

    /// 썸네일 그림의 아래쪽 가운데에 이름표를 놓는다
    private func place(panel: NSPanel, field: NSTextField, text: String, over button: CGRect) {
        let thumbnail = thumbnailRect(in: button)
        // 썸네일 높이에 맞춰 글자 크기를 정한다 (썸네일이 작으므로 작게)
        var pointSize = max(10, min(16, (thumbnail.height * 0.26).rounded()))
        let maxWidth = thumbnail.width * 0.96
        while pointSize > 8 {
            field.font = .systemFont(ofSize: pointSize, weight: .bold)
            field.stringValue = text
            field.sizeToFit()
            if field.frame.width + 12 <= maxWidth { break }
            pointSize -= 1
        }
        field.font = .systemFont(ofSize: pointSize, weight: .bold)
        field.stringValue = text
        field.sizeToFit()

        let width = min(field.frame.width + 12, maxWidth)
        let height = field.frame.height + 6
        panel.contentView?.layer?.cornerRadius = (height * 0.3).rounded()
        field.frame = CGRect(x: 6, y: 3, width: width - 12, height: field.frame.height)
        panel.contentView?.frame = CGRect(x: 0, y: 0, width: width, height: height)

        let origin = CGPoint(x: thumbnail.midX - width / 2, y: thumbnail.minY + 3)
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    var diagnostics: String {
        "공간 막대 덧그리기: \(running ? (isShowing ? "표시 중" : "대기") : "꺼짐")"
            + "\(everWorked ? " (성공한 적 있음 → 예전 배지는 끔)" : "")  / \(lastNote)"
    }
}
