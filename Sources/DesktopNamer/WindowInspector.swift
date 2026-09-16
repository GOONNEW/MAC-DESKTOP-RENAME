import AppKit

/// 공간 하나에 창을 열어 둔 앱
struct SpaceApp: Hashable, Identifiable {
    let pid: pid_t
    let name: String
    let windowCount: Int

    var id: pid_t { pid }

    var icon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }
}

/// 열려 있는 창을 훑어 공간별로 어떤 앱이 있는지 정리한다.
enum WindowInspector {
    static func appsBySpace() -> [CGSSpaceID: [SpaceApp]] {
        guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        var counts: [CGSSpaceID: [pid_t: (name: String, count: Int)]] = [:]
        for info in list {
            // layer 0 = 일반 앱 창. 메뉴 막대 항목, 팝업 등은 제외
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let name = info[kCGWindowOwnerName as String] as? String,
                  let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 100, bounds.height >= 60 else { continue }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0 else { continue }

            for space in SkyLight.spaceIDs(forWindow: windowID) {
                var perApp = counts[space] ?? [:]
                let current = perApp[pid] ?? (name, 0)
                perApp[pid] = (name, current.count + 1)
                counts[space] = perApp
            }
        }

        return counts.mapValues { perApp in
            perApp
                .map { SpaceApp(pid: $0.key, name: $0.value.name, windowCount: $0.value.count) }
                .sorted {
                    $0.windowCount != $1.windowCount ? $0.windowCount > $1.windowCount : $0.name < $1.name
                }
        }
    }

    /// 앱 아이콘 여러 개를 가로로 이어 붙인 이미지 (메뉴 항목용)
    static func iconStrip(for apps: [SpaceApp], maxCount: Int = 4, iconSize: CGFloat = 16, gap: CGFloat = 3) -> NSImage? {
        let shown = Array(apps.prefix(maxCount))
        guard !shown.isEmpty else { return nil }
        let width = CGFloat(shown.count) * iconSize + CGFloat(shown.count - 1) * gap
        return NSImage(size: NSSize(width: width, height: iconSize), flipped: false) { _ in
            for (index, app) in shown.enumerated() {
                let rect = NSRect(x: CGFloat(index) * (iconSize + gap), y: 0, width: iconSize, height: iconSize)
                app.icon?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
    }

    /// "Safari, Finder 외 2개" 형태의 요약
    static func summary(for apps: [SpaceApp], maxNames: Int = 3) -> String {
        guard !apps.isEmpty else { return "" }
        let names = apps.prefix(maxNames).map(\.name).joined(separator: ", ")
        let rest = apps.count - maxNames
        return rest > 0 ? "\(names) 외 \(rest)개" : names
    }
}
