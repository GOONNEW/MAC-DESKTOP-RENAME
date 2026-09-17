import AppKit
import Combine

/// 데스크탑마다 "이름 배지" 창을 하나씩 둔다.
///
/// 배지는 평소엔 완전히 투명해서 보이지 않고, Mission Control이 열릴 것 같은 순간에만 보이게 바꾼다.
/// Mission Control 썸네일은 각 데스크탑을 실시간으로 축소해 보여주므로, 배지가 썸네일 안에 이름으로 나타난다.
/// 창은 그 데스크탑이 활성일 때 만들어야 그 데스크탑에 속하므로, 데스크탑을 방문할 때마다 없는 배지를 만든다.
final class BadgeManager {
    enum Corner: String, CaseIterable {
        case bottomRight, bottomLeft, topRight, topLeft

        var title: String {
            switch self {
            case .bottomRight: return "오른쪽 아래"
            case .bottomLeft: return "왼쪽 아래"
            case .topRight: return "오른쪽 위"
            case .topLeft: return "왼쪽 위"
            }
        }
    }

    private let spaces: SpaceManager
    private let names: NameStore

    /// 공간 UUID → 화면마다 하나씩인 배지 창들
    private var badges: [String: [NSPanel]] = [:]
    private var fields: [String: [NSTextField]] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var running = false
    private(set) var isVisible = false
    private var hideTimer: Timer?
    /// 아무 닫힘 신호도 못 받았을 때 스스로 숨기기까지의 시간
    private let autoHideAfter: TimeInterval = 20
    private var shownAt: Date?
    private var events: [String] = []

    var corner: Corner = .bottomRight {
        didSet { badges.keys.forEach { layout(uuid: $0) } }
    }

    enum Size: String, CaseIterable {
        case medium, large, huge

        var title: String {
            switch self {
            case .medium: return "보통"
            case .large: return "크게"
            case .huge: return "아주 크게"
            }
        }

        /// 화면 높이 대비 글자 크기 비율
        var ratio: CGFloat {
            switch self {
            case .medium: return 0.10
            case .large: return 0.16
            case .huge: return 0.24
            }
        }
    }

    var size: Size = .large {
        didSet { badges.keys.forEach { layout(uuid: $0) } }
    }

    /// true면 주 화면에만 배지를 만든다 (듀얼 모니터에서 한쪽만 보이게)
    var mainScreenOnly = true {
        didSet {
            guard mainScreenOnly != oldValue else { return }
            rebuildAll()
        }
    }

    /// 보조 화면에도 현재 데스크탑 이름을 함께 띄운다 (디스플레이마다 공간 분리가 꺼진 경우용)
    var mirrorToOtherScreens = false {
        didSet {
            guard mirrorToOtherScreens != oldValue else { return }
            if !mirrorToOtherScreens { removeMirrors() }
        }
    }

    /// 보조 화면에 띄우는 배지 (데스크탑에 속하지 않고 모든 공간을 따라다닌다)
    private var mirrors: [NSPanel] = []
    private var mirrorFields: [NSTextField] = []

    private let margin = CGSize(width: 40, height: 96) // 아래쪽은 Dock 자리를 피한다

    init(spaces: SpaceManager, names: NameStore) {
        self.spaces = spaces
        self.names = names
    }

    var isRunning: Bool { running }

    func start() {
        guard !running else { return }
        running = true

        // 활성 데스크탑이 바뀔 때마다 그 데스크탑의 배지를 준비한다
        spaces.$activeSpace
            .compactMap { $0 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] space in self?.ensureBadge(for: space) }
            .store(in: &cancellables)

        // 이름이 바뀌면 글자를 갱신한다
        names.$names
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshTexts() }
            .store(in: &cancellables)

        // 사라진 데스크탑의 배지는 닫는다
        spaces.$spaces
            .map { Set($0.map(\.uuid)) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] uuids in self?.removeBadges(notIn: uuids) }
            .store(in: &cancellables)

        if let active = spaces.activeSpace { ensureBadge(for: active) }

        // 앱을 켤 때마다 배지를 다시 만들어야 하므로, 이름이 지정된 데스크탑이 있으면 자동으로 준비한다.
        // 데스크탑을 한 바퀴 도는 작업이라 화면이 잠깐 바뀐다.
        if autoPrepare {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.running, !self.names.names.isEmpty else { return }
                self.log("시작 시 자동 준비")
                self.prepareAllBadges { message in
                    self.log("자동 준비 결과: \(message.replacingOccurrences(of: "\n", with: " "))")
                }
            }
        }
    }

    /// 앱을 켤 때 배지를 자동으로 준비한다
    var autoPrepare = true

    func stop() {
        running = false
        cancellables.removeAll()
        hideTimer?.invalidate()
        badges.values.forEach { $0.forEach { $0.orderOut(nil) } }
        badges.removeAll()
        fields.removeAll()
        alphas.removeAll()
        namedCache.removeAll()
        reassertWork?.cancel()
        removeMirrors()
        isVisible = false
    }

    // MARK: - 보이기/숨기기

    /// Mission Control이 열릴 것 같을 때: 잠깐 뒤(애니메이션이 시작될 즈음) 배지를 보이게 한다.
    func show(reason: String) {
        guard running, !isVisible else { return }
        hideTimer?.invalidate()
        // 지연 없이 즉시 띄운다. macOS는 Mission Control을 열 때 현재 데스크탑 화면을
        // 한 번 찍어 썸네일로 쓰는데, 그 순간보다 배지가 늦으면 썸네일에 찍히지 않는다.
        setVisible(true)
        shownAt = Date()
        log("표시 (\(reason))")
        armAutoHide()
    }

    /// 아직 Mission Control이 열려 있음이 확인되었을 때: 자동 숨김 시각을 미룬다.
    /// 오래 열어 두어도 이름이 먼저 사라지지 않게 한다.
    func keepAlive() {
        guard running, isVisible else { return }
        armAutoHide()
    }

    /// 닫힘 신호를 모두 놓쳤을 때의 마지막 보루.
    /// 실제로 열려 있음이 확인되는 동안에는 keepAlive()가 계속 다시 걸어 준다.
    private func armAutoHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: autoHideAfter, repeats: false) { [weak self] _ in
            self?.hide(reason: "시간 초과")
        }
    }

    func hide(reason: String) {
        guard isVisible else { return }
        // 막 보이기 시작한 직후(여는 제스처의 잔여 이벤트)는 무시한다
        if let shownAt, Date().timeIntervalSince(shownAt) < 0.35 { return }
        hideTimer?.invalidate()
        setVisible(false)
        shownAt = nil
        log("숨김 (\(reason))")
    }

    /// Mission Control이 열려 있는 동안에는 지금 보고 있는 데스크탑을 포함해
    /// 모든 데스크탑 이름을 계속 띄운다. 평소 화면에서는 전부 투명하게 둔다.
    private func setVisible(_ visible: Bool) {
        isVisible = visible
        reassertWork?.cancel()
        reassertWork = nil
        for uuid in badges.keys {
            applyAlpha(visible && hasName(uuid) ? 1 : 0, to: uuid)
        }
        updateMirrors(visible: visible)
        if visible { scheduleReassert() }
    }

    /// 알파 값을 애니메이션 없이 즉시 적용한다.
    ///
    /// `panel.animator().alphaValue`를 쓰면 0.25초짜리 암시적 애니메이션이 시작되는데,
    /// 그 애니메이션은 뒤에 이어지는 직접 대입(`panel.alphaValue = ...`)을 매 프레임 덮어쓴다.
    /// 배경 데스크탑에 있는 창은 화면 갱신이 늦어 애니메이션이 끝까지 돌지 않는 경우가 있어,
    /// 한 번 0으로 페이드된 배지가 다시 1로 돌아오지 못한 채 남아 있었다. (데스크탑 3 증상)
    private func applyAlpha(_ alpha: CGFloat, to uuid: String) {
        guard let panels = badges[uuid] else { return }
        alphas[uuid] = alpha
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            panels.forEach { panel in
                panel.alphaValue = alpha
                // 배경 데스크탑의 창은 알파만 바꾸면 창 서버가 다시 그리지 않는 일이 있다.
                // 내용을 다시 그리게 해서 썸네일에 확실히 반영되게 한다.
                if alpha > 0, let view = panel.contentView {
                    view.setNeedsDisplay(view.bounds)
                    panel.displayIfNeeded()
                }
            }
        }
    }

    /// 안전망: 표시 직후 한 번 더 모든 배지의 알파를 확인해 바로잡는다.
    ///
    /// 창 서버가 배경 데스크탑의 창을 늦게 갱신하는 일이 있어, 한 번 더 값을 못 박아 둔다.
    private func scheduleReassert() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isVisible else { return }
            for uuid in self.badges.keys {
                let want: CGFloat = self.hasName(uuid) ? 1 : 0
                if self.alphas[uuid] != want || self.badges[uuid]?.first?.alphaValue != want {
                    self.applyAlpha(want, to: uuid)
                    self.log("알파 보정: \(self.spaces.spaces.first(where: { $0.uuid == uuid })?.defaultName ?? uuid) → \(want)")
                }
            }
        }
        reassertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private var reassertWork: DispatchWorkItem?
    /// 배지마다 마지막으로 적용한 알파 (진단용)
    private var alphas: [String: CGFloat] = [:]

    // MARK: - 보조 화면 미러

    private func updateMirrors(visible: Bool) {
        guard mirrorToOtherScreens, mainScreenOnly else {
            removeMirrors()
            return
        }
        guard visible, let active = spaces.activeSpace, let name = names.customName(for: active) else {
            mirrors.forEach { $0.alphaValue = 0 }
            return
        }
        let targets = Array(NSScreen.screens.dropFirst())
        if mirrors.count != targets.count {
            removeMirrors()
            for screen in targets {
                let (panel, field) = makePanel(on: screen, text: name)
                // 미러는 모든 데스크탑을 따라다닌다
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                mirrors.append(panel)
                mirrorFields.append(field)
            }
        }
        for (index, panel) in mirrors.enumerated() {
            guard index < targets.count, index < mirrorFields.count else { continue }
            mirrorFields[index].stringValue = name
            layoutPanel(panel, field: mirrorFields[index], on: targets[index])
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    private func removeMirrors() {
        mirrors.forEach { $0.orderOut(nil) }
        mirrors.removeAll()
        mirrorFields.removeAll()
    }

    /// 5초 동안 배지를 보여 준다 (제대로 뜨는지 눈으로 확인용)
    func preview() {
        guard running else { return }
        hideTimer?.invalidate()
        setVisible(true)
        shownAt = Date().addingTimeInterval(-1)
        log("미리 보기")
        hideTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.hide(reason: "미리 보기 종료")
        }
    }

    /// 공간 목록이 잠시 비거나 갱신 중이면 마지막으로 알던 값을 쓴다.
    /// (목록이 비었을 때 false가 되어 배지가 통째로 꺼지는 일이 있었다)
    private var namedCache: [String: Bool] = [:]

    private func hasName(_ uuid: String) -> Bool {
        guard let space = spaces.spaces.first(where: { $0.uuid == uuid }) else {
            return namedCache[uuid] ?? false
        }
        let has = names.customName(for: space) != nil
        namedCache[uuid] = has
        return has
    }

    // MARK: - 배지 창

    private func ensureBadge(for space: Space) {
        guard running, space.isActive, !space.isFullscreen else { return }
        if let existing = badges[space.uuid] {
            // 이 데스크탑이 지금 활성인데도 창이 어느 화면에도 붙어 있지 않다면,
            // 창이 데스크탑 소속을 잃은 것이다. 이 경우 스스로 다시 만든다.
            guard existing.contains(where: { $0.screen == nil }) else { return }
            log("배지 복구: \(space.defaultName) (화면 소속을 잃음)")
            existing.forEach { $0.orderOut(nil) }
            badges.removeValue(forKey: space.uuid)
            fields.removeValue(forKey: space.uuid)
            alphas.removeValue(forKey: space.uuid)
        }
        var panels: [NSPanel] = []
        var texts: [NSTextField] = []
        // NSScreen.main은 키 창이 있는 화면이라 바뀔 수 있다. 메뉴 막대가 있는 화면(screens[0])으로 고정한다.
        let targets = mainScreenOnly ? [NSScreen.screens[0]] : NSScreen.screens
        for screen in targets {
            let (panel, field) = makePanel(on: screen, text: names.displayName(for: space))
            panels.append(panel)
            texts.append(field)
        }
        guard !panels.isEmpty else { return }
        badges[space.uuid] = panels
        fields[space.uuid] = texts
        layout(uuid: space.uuid)
        applyAlpha(isVisible && hasName(space.uuid) ? 1 : 0, to: space.uuid)
        log("배지 생성: \(space.defaultName) (화면 \(panels.count)개)")
    }

    private func makePanel(on screen: NSScreen, text: String) -> (NSPanel, NSTextField) {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: (screen.frame.height * size.ratio).rounded(), weight: .heavy)
        field.textColor = .white
        field.alignment = .center
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1

        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.13, alpha: 0.85).cgColor
        container.layer?.cornerRadius = 22
        container.addSubview(field)

        let panel = NSPanel(
            contentRect: CGRect(x: screen.frame.minX, y: screen.frame.minY, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0
        panel.isReleasedWhenClosed = false
        // 창 위에 떠야 썸네일에서 확실히 보인다. 평소엔 완전히 투명이라 방해하지 않는다.
        panel.level = .floating
        // 이 데스크탑에만 속하게 한다. moveToActiveSpace/canJoinAllSpaces가 없어야 따라다니지 않는다.
        panel.collectionBehavior = [.stationary, .ignoresCycle]
        // 앱이 활성화될 때 창을 현재 데스크탑으로 끌어오지 않도록
        panel.isFloatingPanel = true
        panel.contentView = container
        panel.orderFrontRegardless()
        return (panel, field)
    }

    private func refreshTexts() {
        for (uuid, texts) in fields {
            guard let space = spaces.spaces.first(where: { $0.uuid == uuid }) else { continue }
            texts.forEach { $0.stringValue = names.displayName(for: space) }
            layout(uuid: uuid)
            applyAlpha(isVisible && hasName(uuid) ? 1 : 0, to: uuid)
        }
    }

    /// 글자 크기에 맞춰 배지 크기를 정하고 각 화면 구석에 놓는다
    private func layout(uuid: String) {
        guard let panels = badges[uuid], let texts = fields[uuid] else { return }
        for (index, panel) in panels.enumerated() {
            guard index < texts.count else { continue }
            let screen = panel.screen ?? NSScreen.screens[min(index, NSScreen.screens.count - 1)]
            layoutPanel(panel, field: texts[index], on: screen)
        }
    }

    /// 배지 하나를 화면 구석에 맞춰 놓는다
    private func layoutPanel(_ panel: NSPanel, field: NSTextField, on screen: NSScreen) {
        var pointSize = (screen.frame.height * size.ratio).rounded()
        let maxWidth = screen.frame.width * 0.8
        let paddingX = (pointSize * 0.4).rounded()
        let paddingY = (pointSize * 0.22).rounded()
        // 이름이 길면 화면에 들어갈 때까지 글자를 줄인다
        while pointSize > 18 {
            field.font = .systemFont(ofSize: pointSize, weight: .heavy)
            field.sizeToFit()
            if field.frame.width + paddingX * 2 <= maxWidth { break }
            pointSize -= 4
        }
        field.font = .systemFont(ofSize: pointSize, weight: .heavy)
        field.sizeToFit()
        let width = min(field.frame.width + paddingX * 2, maxWidth)
        let height = field.frame.height + paddingY * 2
        (panel.contentView?.layer)?.cornerRadius = (height * 0.28).rounded()
        field.frame = CGRect(x: paddingX, y: paddingY, width: width - paddingX * 2, height: field.frame.height)
        panel.contentView?.frame = CGRect(x: 0, y: 0, width: width, height: height)

        let visible = screen.visibleFrame
        let full = screen.frame
        var origin = CGPoint.zero
        switch corner {
        case .bottomRight:
            origin = CGPoint(x: full.maxX - margin.width - width, y: full.minY + margin.height)
        case .bottomLeft:
            origin = CGPoint(x: full.minX + margin.width, y: full.minY + margin.height)
        case .topRight:
            origin = CGPoint(x: full.maxX - margin.width - width, y: visible.maxY - margin.width - height)
        case .topLeft:
            origin = CGPoint(x: full.minX + margin.width, y: visible.maxY - margin.width - height)
        }
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
    }

    /// 설정이 바뀌면 배지를 다시 만든다 (지금 데스크탑 것만. 나머지는 방문 시 다시 만들어진다)
    private func rebuildAll() {
        badges.values.forEach { $0.forEach { $0.orderOut(nil) } }
        badges.removeAll()
        fields.removeAll()
        alphas.removeAll()
        removeMirrors()
        if let active = spaces.activeSpace { ensureBadge(for: active) }
        log("배지 다시 만듦 (설정 변경)")
    }

    /// 목록에서 사라진 데스크탑의 배지를 닫는다.
    ///
    /// 다만 SkyLight 목록은 전환 중에 잠깐 불완전할 수 있다. 한 번 빠졌다고 바로 닫으면
    /// 그 데스크탑 배지는 직접 방문할 때까지 영영 돌아오지 않는다. 그래서
    /// 두 번 연속 빠졌을 때만 닫고, Mission Control이 떠 있는 동안은 건드리지 않는다.
    private func removeBadges(notIn uuids: Set<String>) {
        guard !isVisible else { return }
        let missing = Set(badges.keys).subtracting(uuids)
        let confirmed = missing.intersection(missingOnce)
        missingOnce = missing.subtracting(confirmed)
        for (uuid, panels) in badges where confirmed.contains(uuid) {
            panels.forEach { $0.orderOut(nil) }
            badges.removeValue(forKey: uuid)
            fields.removeValue(forKey: uuid)
            alphas.removeValue(forKey: uuid)
            namedCache.removeValue(forKey: uuid)
            let name = spaces.spaces.first(where: { $0.uuid == uuid })?.defaultName ?? uuid
            log("배지 닫음: \(name) (목록에서 사라짐)")
        }
    }

    /// 한 번 목록에서 빠졌지만 아직 닫지 않은 데스크탑
    private var missingOnce: Set<String> = []

    // MARK: - 모든 데스크탑 준비

    /// 배지를 모두 버리고 데스크탑을 한 바퀴 돌며 새로 만든다.
    /// 배경 데스크탑의 창은 상태를 확인할 방법이 없으므로, 이름이 안 보일 때 쓰는 확실한 수단이다.
    func rebuildAllBadges(completion: @escaping (String) -> Void) {
        guard running else { completion("이름 표시가 꺼져 있습니다. 먼저 켜 주세요."); return }
        badges.values.forEach { $0.forEach { $0.orderOut(nil) } }
        badges.removeAll()
        fields.removeAll()
        alphas.removeAll()
        missingOnce.removeAll()
        log("모든 배지 버리고 다시 만들기")
        if let active = spaces.activeSpace { ensureBadge(for: active) }
        prepareAllBadges(completion: completion)
    }

    /// 배지가 없는 데스크탑을 차례로 방문해 배지를 만들고 원래 자리로 돌아온다.
    /// 전환은 ⌃숫자 단축키로 하므로, 그 단축키가 꺼져 있으면 실패한다. 실패를 감지해 알려 준다.
    func prepareAllBadges(completion: @escaping (String) -> Void) {
        guard running else { completion("이름 표시가 꺼져 있습니다. 먼저 켜 주세요."); return }
        let missing = spaces.spaces.filter { !$0.isFullscreen && badges[$0.uuid] == nil }
        guard !missing.isEmpty else { completion("모든 데스크탑에 이름이 준비되어 있습니다."); return }

        let targets = missing.compactMap { space in
            space.number.flatMap { SpaceSwitcher.canSwitch(to: $0) ? $0 : nil }
        }
        let origin = spaces.activeSpace?.number
        guard !targets.isEmpty else {
            completion("전환할 수 있는 데스크탑이 없습니다. ⌃숫자 단축키는 데스크탑 10까지만 지원합니다.")
            return
        }

        var queue = targets
        var succeeded: [Int] = []
        var failed: [Int] = []
        /// 단축키가 안 먹으면 직접 전환으로 바꾼다
        var useDirect = false

        func finish() {
            if let origin { SpaceSwitcher.switchTo(number: origin) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self else { return }
                let ready = self.spaces.spaces.filter { !$0.isFullscreen && self.badges[$0.uuid] != nil }.count
                let total = self.spaces.spaces.filter { !$0.isFullscreen }.count
                var message = "데스크탑 \(total)개 중 \(ready)개에 이름을 준비했습니다."
                if !failed.isEmpty {
                    message += "\n\n전환하지 못한 데스크탑: \(failed.map(String.init).joined(separator: ", "))"
                    message += "\n\n각 데스크탑으로 직접 이동만 해도 그때 이름이 만들어집니다. 세 손가락으로 좌우로 쓸어 한 번씩 들러 주세요."
                }
                self.log("준비 완료: 성공 \(succeeded.count), 실패 \(failed.count)")
                completion(message)
            }
        }

        func attempt(_ number: Int, retry: Bool) {
            if useDirect {
                if let space = spaces.spaces.first(where: { $0.number == number }) {
                    SkyLight.switchDirectly(to: space.id, onDisplay: space.displayID)
                }
            } else {
                SpaceSwitcher.switchTo(number: number)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self else { return }
                self.spaces.refresh()
                if let active = self.spaces.activeSpace, active.number == number {
                    self.ensureBadge(for: active)
                    succeeded.append(number)
                    step()
                    return
                }
                // 단축키가 안 먹은 것 같으면 직접 전환으로 한 번 더 시도한다
                if retry, !useDirect, SkyLight.canSwitchDirectly {
                    useDirect = true
                    self.log("단축키 전환 실패 → 직접 전환으로 변경")
                    attempt(number, retry: false)
                    return
                }
                failed.append(number)
                if failed.count >= 2 {
                    failed.append(contentsOf: queue)
                    queue.removeAll()
                }
                step()
            }
        }

        func step() {
            guard let number = queue.first else { finish(); return }
            queue.removeFirst()
            attempt(number, retry: true)
        }
        step()
    }

    // MARK: - 진단

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.S"
        events.append("\(formatter.string(from: Date())) \(message)")
        if events.count > 20 { events.removeFirst(events.count - 20) }
    }

    func diagnostics() -> String {
        var lines: [String] = []
        lines.append("이름 배지: \(running ? "켜짐" : "꺼짐"), 지금 \(isVisible ? "보임" : "숨김"), 위치 \(corner.title), 크기 \(size.title), \(mainScreenOnly ? "주 화면만" : "모든 화면")")
        lines.append("화면 수: \(NSScreen.screens.count), 배지 창 수: \(badges.values.reduce(0) { $0 + $1.count }), 보조 화면 미러: \(mirrorToOtherScreens ? "켜짐 (\(mirrors.count)개)" : "꺼짐")")
        let missing = spaces.spaces.filter { !$0.isFullscreen && badges[$0.uuid] == nil }.map { $0.defaultName }
        lines.append("배지 없는 데스크탑: \(missing.isEmpty ? "없음" : missing.joined(separator: ", "))")
        lines.append("배지 상태 (이름 / 투명도 / 창이 실제로 가진 값):")
        for space in spaces.spaces where badges[space.uuid] != nil {
            let panels = badges[space.uuid] ?? []
            let real = panels.map { String(format: "%.2f", Double($0.alphaValue)) }.joined(separator: ",")
            let want = alphas[space.uuid].map { String(format: "%.2f", Double($0)) } ?? "-"
            let name = names.customName(for: space) ?? "(이름 없음)"
            var marks: [String] = []
            if space.isActive { marks.append("현재") }
            if panels.first?.screen == nil { marks.append("화면 미할당") }
            let suffix = marks.isEmpty ? "" : " [" + marks.joined(separator: ", ") + "]"
            lines.append("  \(space.defaultName) \(name) / 적용 \(want) / 실제 \(real)\(suffix)")
        }
        if !events.isEmpty {
            lines.append("배지 기록:")
            lines.append(contentsOf: events.map { "  " + $0 })
        }
        return lines.joined(separator: "\n")
    }
}
