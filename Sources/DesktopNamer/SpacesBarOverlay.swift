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
    /// 썸네일 안에서 이름표를 놓을 세로 단계 (0 = 맨 위 … 4 = 맨 아래)
    var verticalStep: Int = 1

    /// 각 단계가 버튼 위쪽에서 얼마나 내려온 자리인지
    ///
    /// 접근성이 주는 버튼 영역은 "썸네일 그림 + 아래 글자"가 한 덩어리다. 그림만의 자리를
    /// 알려주는 값이 없어(자식 요소도 없고 AXFrame도 같은 값), 계산으로 맞히려다 여러 번
    /// 어긋났다. 그래서 몇 단계로 나눠 두고 눈으로 고르게 한다.
    static let stepTitles = ["맨 위", "위쪽", "가운데", "아래쪽", "맨 아래"]
    private static let stepFractions: [CGFloat] = [0.12, 0.26, 0.40, 0.54, 0.68]
    /// 글자 크기
    var size: BadgeManager.Size = .large

    private var running = false
    private(set) var lastNote = "시작 안 됨"
    private(set) var isShowing = false
    /// 한 번이라도 이름표를 제대로 올린 적이 있는가.
    /// 이게 true면 데스크탑 안쪽에 두는 예전 배지는 필요 없다.
    private(set) var everWorked = false
    /// 열린 것 같은데 이름표를 올리지 못한 횟수
    private var misses = 0
    private var fellBack = false
    /// 마지막으로 이름표를 놓은 자리 (진단용)
    private(set) var lastPlacement = "-"

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
        let open = SpacesBarAX.isOpen()
        // 접근성 권한이 없어지면(nil) 더 읽을 수 없다. 예전 방식으로 돌아간다.
        if open == nil, everWorked { fallBack(reason: "접근성 권한을 읽을 수 없음"); return }
        // 빠른 확인부터. 닫혀 있고 지금 그린 것도 없으면 트리 전체를 훑지 않는다.
        if open == false, !isShowing { return }
        let scan = SpacesBarAX.scan()
        lastNote = "\(scan.source): \(scan.note)"
        guard !scan.buttons.isEmpty else {
            // 열려 있다는데 공간 막대를 못 찾으면 구조가 바뀐 것이다.
            // 몇 번 이어지면 예전 방식으로 돌아간다.
            if open == true, everWorked {
                misses += 1
                if misses >= 8 { fallBack(reason: "공간 막대를 더 이상 찾지 못함") }
            }
            hide()
            return
        }
        misses = 0

        // 공간 막대의 버튼은 왼쪽부터 차례대로다. 이름을 붙일 것만 골라 짝지운다.
        let labels = matchNames(to: scan.buttons)
        guard !labels.isEmpty else {
            hide()
            return
        }

        ensurePanels(count: labels.count)
        var placed: [String] = []
        for (index, item) in labels.enumerated() {
            place(panel: panels[index], field: fields[index], text: item.name, over: item.frame)
            let f = panels[index].frame
            let b = item.frame
            placed.append("\(item.name): 버튼(\(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))×\(Int(b.height)))"
                + " 이름표(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)))"
                + " 중심차 \(Int(f.midX - b.midX))")
        }
        lastPlacement = placed.joined(separator: "\n    ")
        for extra in labels.count..<panels.count {
            panels[extra].alphaValue = 0
        }
        isShowing = true
        everWorked = true
    }

    /// 더 이상 쓸 수 없으니 예전 배지 방식으로 돌아간다
    private func fallBack(reason: String) {
        guard !fellBack else { return }
        fellBack = true
        lastNote = "되돌림: \(reason)"
        hide()
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
        // 지금 보고 있는 데스크탑 하나만 맡는다.
        //
        // 다른 데스크탑은 안쪽에 둔 배지가 macOS에 의해 통째로 축소되어 썸네일에 담기므로
        // 위치와 크기가 저절로 맞는다. 그 위에 덧그리면 같은 이름이 두 번 보이고,
        // 접근성이 알려주는 자리가 실제 썸네일과 조금씩 달라 오히려 어긋난다.
        // 현재 데스크탑만은 미션 컨트롤이 열리기 직전에 찍은 사진이라 배지가 안 담긴다.
        guard verticalStep >= 0,
              let active = spaces.activeSpace, let number = active.number,
              let name = names.customName(for: active),
              let button = buttons.first(where: { $0.number == number }) else { return [] }
        return [Placement(frame: button.frame, name: name)]
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

    /// 공간 버튼 안에서 "썸네일 그림"이 차지하는 부분을 어림한다.
    ///
    /// 접근성이 알려주는 버튼 영역에는 썸네일 그림과 그 아래 "데스크탑 N" 글자가 함께 들어 있다.
    /// 썸네일 그림은 화면과 같은 비율로 축소된 것이므로, 너비에 화면 비율을 곱하면 높이가 나온다.
    /// 어림이 빗나가도 버튼 밖으로 나가지 않도록 위아래로 묶는다.
    private func thumbnailRect(in button: CGRect) -> CGRect {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(button) })
            ?? NSScreen.screens.first
        let ratio = screen.map { $0.frame.height / $0.frame.width } ?? 0.625
        // 버튼 영역은 "썸네일 그림 + 아래 데스크탑 이름 글자"로 이루어진다.
        // 그림은 화면을 그대로 축소한 것이므로 너비에 화면 비율을 곱하면 높이가 나온다.
        // 실측으로 확인: 버튼 169×129, 버튼 간격 171(좌우 여백 2pt뿐)이고
        // 169 ÷ 1.547 = 109, 129 - 109 = 20 → 남는 20이 글자 자리로 정확히 맞는다.
        let estimated = button.width * ratio
        let height = min(max(estimated, button.height * 0.4), button.height)
        return CGRect(x: button.minX, y: button.maxY - height, width: button.width, height: height)
    }

    /// 썸네일 안에 이름표를 놓는다.
    ///
    /// 어떤 경우에도 버튼 영역 밖으로는 나가지 않게 마지막에 묶는다. 접근성이 알려주는 값이
    /// 늘 정확하지는 않아서(크기가 두 배로 오거나, 여는 도중의 중간값이 섞인다), 계산이
    /// 빗나가면 이름표가 공간 막대 바깥 화면 한가운데에 떠 버렸다.
    private func place(panel: NSPanel, field: NSTextField, text: String, over button: CGRect) {
        // 글자 크기를 정할 때만 쓴다. 놓는 자리는 아래에서 단계로 정한다.
        let thumbnail = thumbnailRect(in: button)
        // 썸네일 높이에 맞춰 글자 크기를 정한다. 설정의 비율을 그대로 쓰면 썸네일에서는
        // 너무 커서, 비율만 가져와 줄이고 위아래로 묶는다.
        let ratio = size.ratio * 1.4
        var pointSize = max(9, min(20, (thumbnail.height * ratio).rounded()))
        // 이름표는 버튼보다 넓을 수 없다
        let maxWidth = max(24, button.width - 8)
        while pointSize > 8 {
            field.font = .systemFont(ofSize: pointSize, weight: .bold)
            field.stringValue = text
            field.sizeToFit()
            if field.frame.width + 10 <= maxWidth { break }
            pointSize -= 1
        }
        field.font = .systemFont(ofSize: pointSize, weight: .bold)
        field.stringValue = text
        field.sizeToFit()

        let width = min(field.frame.width + 10, maxWidth)
        let height = min(field.frame.height + 5, max(14, button.height - 4))
        panel.contentView?.layer?.cornerRadius = (height * 0.3).rounded()
        field.frame = CGRect(x: 5, y: (height - field.frame.height) / 2,
                             width: width - 10, height: field.frame.height)
        panel.contentView?.frame = CGRect(x: 0, y: 0, width: width, height: height)

        // 가로는 언제나 가운데에 놓는다.
        //
        // 접근성이 알려주는 버튼 영역은 실제 썸네일보다 넓다(좌우 여백 포함). 그래서 오른쪽에
        // 붙이면 이름표가 옆 썸네일 쪽으로 밀려난다. 실제로 이름이 한 칸씩 오른쪽으로 치우쳐
        // 보였고, 어긋난 정도가 끝까지 일정했다. 배율이 아니라 정렬 때문이라는 뜻이다.
        // 버튼 영역과 썸네일은 중심이 같으므로, 가운데에 놓으면 너비를 잘못 알아도 맞는다.
        var x = button.midX - width / 2
        let step = min(max(verticalStep, 0), Self.stepFractions.count - 1)
        let centerY = button.maxY - button.height * Self.stepFractions[step]
        var y = centerY - height / 2
        // 마지막 안전장치: 버튼 영역을 벗어나지 않게 민다
        x = min(max(x, button.minX), button.maxX - width)
        y = min(max(y, button.minY), button.maxY - height)

        panel.setFrame(CGRect(x: x, y: y, width: width, height: height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    var diagnostics: String {
        "공간 막대 덧그리기: \(running ? (isShowing ? "표시 중" : "대기") : "꺼짐")"
            + "\(everWorked ? " (성공한 적 있음 → 예전 배지는 끔)" : "") / \(lastNote)"
            + "\n  마지막으로 놓은 자리: \(lastPlacement)"
    }
}
