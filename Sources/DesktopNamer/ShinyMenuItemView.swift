import AppKit

/// 눈에 띄어야 하는 메뉴 항목. 알약 모양 배경 위로 밝은 띠가 지나가는 반사 효과를 준다.
///
/// 기본 NSMenuItem은 글꼴이나 배경을 바꿀 수 없어서 직접 그린다.
/// 직접 그리는 항목은 클릭과 강조 표시도 스스로 처리해야 한다.
final class ShinyMenuItemView: NSView {
    private let title: String
    private var hovering = false
    /// 반사 띠의 진행도 (0~1). 0.5를 넘으면 잠깐 쉰다.
    private var phase: CGFloat = 0
    private var timer: Timer?

    /// 메뉴 항목의 좌우 여백 (체크 표시 자리를 피해 다른 항목과 글자를 맞춘다)
    private let insetX: CGFloat = 14
    private let textInsetX: CGFloat = 22

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        let size = (title as NSString).size(withAttributes: [.font: Self.font])
        frame = NSRect(x: 0, y: 0, width: size.width + textInsetX + insetX + 20, height: 30)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("코드로만 만든다") }

    private static var font: NSFont {
        .systemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .semibold)
    }

    // MARK: - 애니메이션

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAnimating() } else { startAnimating() }
    }

    private func startAnimating() {
        guard timer == nil else { return }
        phase = 0
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            // 메뉴가 닫혔는데 알림을 놓쳤을 때를 대비해 여기서도 확인한다
            guard self.window != nil else { self.stopAnimating(); return }
            // 한 바퀴 2.4초: 앞쪽 절반에 띠가 지나가고 뒤쪽 절반은 쉰다
            self.phase += (1.0 / 30) / 2.4
            if self.phase > 1 { self.phase -= 1 }
            self.needsDisplay = true
        }
        // 메뉴가 열려 있는 동안에도 돌아가야 하므로 .common 모드로 넣는다
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopAnimating() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    // MARK: - 마우스

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    /// 직접 그리는 항목은 클릭이 자동으로 전달되지 않는다
    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, let menu = item.menu else { return }
        let index = menu.index(of: item)
        menu.cancelTracking()
        if index >= 0 { menu.performActionForItem(at: index) }
    }

    // MARK: - 그리기

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSRect(x: insetX - 8, y: 3, width: bounds.width - (insetX - 8) - 8, height: bounds.height - 6)
        let path = NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7)
        let accent = NSColor.controlAccentColor

        // 배경: 강조색을 옅게. 마우스를 올리면 진하게.
        (hovering ? accent : accent.withAlphaComponent(0.16)).setFill()
        path.fill()

        // 반사 띠: 알약 안쪽만 칠하도록 잘라 낸다
        NSGraphicsContext.saveGraphicsState()
        path.setClip()
        drawShine(in: pill)
        NSGraphicsContext.restoreGraphicsState()

        let color: NSColor = hovering ? .white : accent
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: textInsetX, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    /// 왼쪽에서 오른쪽으로 지나가는 밝은 띠
    private func drawShine(in rect: NSRect) {
        // 뒤쪽 절반은 쉬는 구간
        guard phase < 0.5 else { return }
        let progress = phase / 0.5
        let bandWidth = max(60, rect.width * 0.28)
        // 띠가 화면 밖에서 시작해 밖으로 빠져나가게 한다
        let centerX = rect.minX - bandWidth + (rect.width + bandWidth * 2) * progress

        let stops: [CGFloat] = [0, 0.5, 1]
        guard let gradient = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0),
            NSColor.white.withAlphaComponent(hovering ? 0.55 : 0.4),
            NSColor.white.withAlphaComponent(0),
        ], atLocations: stops, colorSpace: .deviceRGB) else { return }

        // 살짝 기울여 유리에 빛이 스치는 느낌을 준다
        let band = NSRect(x: centerX - bandWidth / 2, y: rect.minY - 6,
                          width: bandWidth, height: rect.height + 12)
        let skewed = NSBezierPath()
        let lean: CGFloat = 10
        skewed.move(to: NSPoint(x: band.minX + lean, y: band.minY))
        skewed.line(to: NSPoint(x: band.maxX + lean, y: band.minY))
        skewed.line(to: NSPoint(x: band.maxX - lean, y: band.maxY))
        skewed.line(to: NSPoint(x: band.minX - lean, y: band.maxY))
        skewed.close()

        NSGraphicsContext.saveGraphicsState()
        skewed.setClip()
        gradient.draw(in: band, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }
}
