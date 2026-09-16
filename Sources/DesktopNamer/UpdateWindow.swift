import AppKit

/// 업데이트 진행 창. 단계별 진행 막대와 상태 문구를 보여 준다.
final class UpdateWindowController {
    private var window: NSWindow?
    private var titleLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var detailView: NSTextView!
    private var detailScroll: NSScrollView!
    private var actionButton: NSButton!
    private var spinner: NSProgressIndicator!

    private var onCancel: (() -> Void)?
    private var onClose: (() -> Void)?

    func show(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        if window == nil { build() }
        reset()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    // MARK: - 상태 갱신

    /// 진행 단계를 0~1 사이 값으로 갱신한다
    func setProgress(_ fraction: Double, status: String) {
        progressBar.isIndeterminate = false
        progressBar.doubleValue = min(max(fraction, 0), 1) * 100
        statusLabel.stringValue = status
    }

    func appendLog(_ text: String) {
        guard !text.isEmpty else { return }
        detailView.string += text
        detailView.scrollToEndOfDocument(nil)
    }

    func finish(success: Bool, message: String, onClose: @escaping () -> Void) {
        self.onClose = onClose
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        progressBar.isIndeterminate = false
        progressBar.doubleValue = 100
        titleLabel.stringValue = success ? "업데이트 완료" : "업데이트 실패"
        statusLabel.stringValue = message
        statusLabel.textColor = success ? .secondaryLabelColor : .systemRed
        actionButton.title = success ? "새 버전으로 시작" : "닫기"
        actionButton.action = #selector(finishAction(_:))
        actionButton.keyEquivalent = "\r"
        if !success { detailScroll.isHidden = false }
    }

    // MARK: - 만들기

    private func build() {
        let width: CGFloat = 460
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 330))

        titleLabel = NSTextField(labelWithString: "최신 버전으로 업데이트")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.frame = NSRect(x: 24, y: 276, width: width - 48, height: 24)
        content.addSubview(titleLabel)

        spinner = NSProgressIndicator(frame: NSRect(x: width - 48, y: 278, width: 20, height: 20))
        spinner.style = .spinning
        spinner.controlSize = .small
        content.addSubview(spinner)

        statusLabel = NSTextField(labelWithString: "준비 중…")
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: 24, y: 248, width: width - 48, height: 20)
        content.addSubview(statusLabel)

        progressBar = NSProgressIndicator(frame: NSRect(x: 24, y: 222, width: width - 48, height: 8))
        progressBar.isIndeterminate = true
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.style = .bar
        content.addSubview(progressBar)

        detailView = NSTextView(frame: NSRect(x: 0, y: 0, width: width - 48, height: 140))
        detailView.isEditable = false
        detailView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detailView.textColor = .secondaryLabelColor
        detailView.isVerticallyResizable = true
        detailView.textContainer?.widthTracksTextView = true

        detailScroll = NSScrollView(frame: NSRect(x: 24, y: 60, width: width - 48, height: 140))
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder
        detailScroll.documentView = detailView
        detailScroll.isHidden = true
        content.addSubview(detailScroll)

        let toggle = NSButton(frame: NSRect(x: 18, y: 20, width: 110, height: 24))
        toggle.title = "자세히 보기"
        toggle.bezelStyle = .inline
        toggle.isBordered = false
        toggle.contentTintColor = .controlAccentColor
        toggle.target = self
        toggle.action = #selector(toggleDetail(_:))
        content.addSubview(toggle)

        actionButton = NSButton(frame: NSRect(x: width - 134, y: 16, width: 110, height: 32))
        actionButton.title = "취소"
        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(cancelAction(_:))
        content.addSubview(actionButton)

        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "DesktopNamer 업데이트"
        window.contentView = content
        window.isReleasedWhenClosed = false
        self.window = window
    }

    private func reset() {
        titleLabel.stringValue = "최신 버전으로 업데이트"
        statusLabel.stringValue = "준비 중…"
        statusLabel.textColor = .secondaryLabelColor
        detailView.string = ""
        detailScroll.isHidden = true
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        spinner.isHidden = false
        spinner.startAnimation(nil)
        actionButton.title = "취소"
        actionButton.action = #selector(cancelAction(_:))
        actionButton.keyEquivalent = ""
    }

    @objc private func toggleDetail(_ sender: NSButton) {
        detailScroll.isHidden.toggle()
        sender.title = detailScroll.isHidden ? "자세히 보기" : "간단히 보기"
    }

    @objc private func cancelAction(_ sender: Any?) {
        onCancel?()
        close()
    }

    @objc private func finishAction(_ sender: Any?) {
        onClose?()
        close()
    }
}
