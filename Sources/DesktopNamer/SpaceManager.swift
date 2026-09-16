import AppKit
import Combine

/// 공간 목록과 현재 공간을 추적한다.
final class SpaceManager: ObservableObject {
    @Published private(set) var spaces: [Space] = []
    @Published private(set) var activeSpace: Space?
    /// 공간 ID → 창을 열어 둔 앱 목록. `refreshApps()`로 갱신한다.
    @Published private(set) var appsBySpace: [CGSSpaceID: [SpaceApp]] = [:]

    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?

    func start() {
        refresh()

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() })

        // 공간 추가/삭제는 알림이 오지 않으므로 느리게 폴링한다.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() {
        let displays = SkyLight.managedDisplaySpaces()
        let activeID = SkyLight.activeSpaceID()

        var result: [Space] = []
        var number = 0

        for display in displays {
            guard let displayID = display["Display Identifier"] as? String,
                  let list = display["Spaces"] as? [[String: Any]] else { continue }
            for entry in list {
                guard let uuid = entry["uuid"] as? String else { continue }
                let id = (entry["id64"] as? NSNumber)?.uint64Value
                    ?? (entry["ManagedSpaceID"] as? NSNumber)?.uint64Value
                    ?? 0
                // type 0: 일반 데스크탑, 4: 전체 화면/분할 보기
                let type = (entry["type"] as? NSNumber)?.intValue ?? 0
                let isFullscreen = type != 0
                if !isFullscreen { number += 1 }
                result.append(Space(
                    id: id,
                    uuid: uuid,
                    displayID: displayID,
                    number: isFullscreen ? nil : number,
                    isFullscreen: isFullscreen,
                    isActive: id == activeID
                ))
            }
        }

        if result != spaces { spaces = result }
        let active = result.first(where: \.isActive)
        if active != activeSpace { activeSpace = active }
    }

    func refreshApps() {
        appsBySpace = WindowInspector.appsBySpace()
    }

    func apps(in space: Space) -> [SpaceApp] {
        appsBySpace[space.id] ?? []
    }

    /// macOS 단축키(⌃숫자)를 대신 눌러 전환한다. 전체 화면 공간이나 11번째 이후 데스크탑은 지원하지 않는다.
    func switchTo(_ space: Space) {
        guard let number = space.number, SpaceSwitcher.canSwitch(to: number) else { return }
        SpaceSwitcher.switchTo(number: number)
        // 전환 알림이 늦게 올 수 있으므로 잠시 후 한 번 더 갱신
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
    }
}
