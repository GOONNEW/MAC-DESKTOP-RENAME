import AppKit
import CoreGraphics

/// Mission Control이 "정말로" 열려 있는지 확인한다.
///
/// 가장 확실한 방법은 WindowServer가 직접 보내는 알림(1204 열림 / 1207 닫힘)이다.
/// 그게 오면 그것만 믿는다. (`SkyLight.registerMissionControlNotifications`)
///
/// 알림이 오지 않는 macOS를 대비해, 화면 상태를 재는 지표도 함께 모은다.
/// 어떤 지표가 Mission Control 상태를 구분하는지는 macOS 버전마다 다르므로
/// 여러 개를 동시에 재 두고, 평소와 열림이 확실히 갈리는 지표를 스스로 고른다.
/// (첫 시도에서 쓴 "Dock 창 개수"는 이 맥에서 평소 1개, 열림 1개로 구분이 안 됐다.)
final class MissionControlProbe {

    // MARK: - 지표

    /// 한 번에 재는 값들. 이름은 진단 창에 그대로 나온다.
    static let metricNames = [
        "화면 위 창 수",
        "Dock 창 수",
        "레이어 1 이상 창",
        "가장 높은 레이어",
        "화면 덮는 창 수",
        "창 가진 앱 수",
        "Dock이 최상위",
        "공간 수",
    ]

    /// 지금 값을 한 번에 잰다. 창 목록은 한 번만 읽는다.
    static func sample() -> [Int] {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []

        var dockWindows = 0
        var aboveNormal = 0
        var maxLayer = -9999
        var covering = 0
        var owners = Set<String>()

        // 주 화면 넓이의 70% 이상을 덮는 창을 "화면 덮는 창"으로 본다
        let screenArea = NSScreen.screens.first.map { $0.frame.width * $0.frame.height } ?? 0

        for info in list {
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            owners.insert(owner)
            if owner == "Dock" { dockWindows += 1 }
            if layer >= 1 { aboveNormal += 1 }
            maxLayer = max(maxLayer, layer)
            if screenArea > 0,
               let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
               let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
               bounds.width * bounds.height >= screenArea * 0.7 {
                covering += 1
            }
        }

        let frontIsDock = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.dock" ? 1 : 0
        let spaceCount = SkyLight.managedDisplaySpaces().reduce(0) { total, display in
            total + ((display["Spaces"] as? [[String: Any]])?.count ?? 0)
        }

        return [list.count, dockWindows, aboveNormal, maxLayer, covering, owners.count, frontIsDock, spaceCount]
    }

    // MARK: - 알림 (가장 확실한 신호)

    /// "열림(1204)" 알림을 한 번이라도 받았는가.
    ///
    /// 열림 알림을 받아 본 적이 있어야만 이 신호를 믿는다. 닫힘 알림만 오는 macOS에서
    /// 이 값을 켜 버리면 "항상 닫혀 있다"고 판단해 이름이 아예 안 뜨게 된다.
    private(set) var notificationsWork = false
    private(set) var notificationCount = 0
    private(set) var lastNotification: UInt32?
    private(set) var registerNote = "등록 전"
    /// 알림 기준으로 지금 열려 있는가
    private(set) var openByNotification = false

    /// 알림이 오지 않는 동안에만 화면 지표를 재면 된다
    var usesMetrics: Bool { !notificationsWork }

    func noteRegistered(_ note: String) {
        registerNote = note
    }

    /// 1204 열림 / 1205 앱 창 보기 / 1206 데스크탑 보기 / 1207 닫힘
    func noteNotification(_ type: UInt32) {
        notificationCount += 1
        lastNotification = type
        if type == 1204 { notificationsWork = true }
        openByNotification = (type == 1204)
    }

    // MARK: - 지표 학습

    /// 틀린 것으로 판명돼 쓰지 않는 지표 번호
    private var bannedMetrics: Set<Int> = []
    private var quiet: [[Int]] = Array(repeating: [], count: metricNames.count)
    private var open: [[Int]] = Array(repeating: [], count: metricNames.count)
    /// 가장 최근에 잰 지표 값들
    private var lastValues: [Int] = Array(repeating: 0, count: metricNames.count)

    private static let quietWindow = 60
    private static let openWindow = 20

    func noteQuiet() {
        let values = Self.sample()
        lastValues = values
        for index in values.indices {
            quiet[index].append(values[index])
            if quiet[index].count > Self.quietWindow {
                quiet[index].removeFirst(quiet[index].count - Self.quietWindow)
            }
        }
    }

    func noteOpen() {
        let values = Self.sample()
        lastValues = values
        for index in values.indices {
            open[index].append(values[index])
            if open[index].count > Self.openWindow {
                open[index].removeFirst(open[index].count - Self.openWindow)
            }
        }
    }

    func reset() {
        quiet = Array(repeating: [], count: Self.metricNames.count)
        open = Array(repeating: [], count: Self.metricNames.count)
        bannedMetrics.removeAll()
    }

    /// "열려 있다"는 판단이 틀렸음이 드러났을 때 부른다.
    ///
    /// 사용자가 평소 화면에서 클릭하고 입력하는데도 계속 열려 있다고 하면, 그 근거는
    /// 틀린 것이다. 그대로 두면 이름표가 화면에 영원히 남는다. (실제로 그랬다)
    /// 알림을 믿고 있었다면 닫힌 것으로 되돌리고, 지표를 쓰고 있었다면 그 지표를 버린다.
    func distrust() {
        if notificationsWork {
            openByNotification = false
            return
        }
        if let index = choice?.index {
            bannedMetrics.insert(index)
            distrustNote = "\(Self.metricNames[index]) 지표를 버림"
        } else {
            distrustNote = "버릴 지표가 없어 학습을 초기화"
            reset()
        }
    }

    private(set) var distrustNote: String?

    /// "Dock이 최상위" 지표의 번호.
    ///
    /// Mission Control이 떠 있는 동안에는 Dock이 활성 앱이 된다. 뜻이 분명한 신호이므로,
    /// 구분이 되기만 하면 차이(gap)가 작아도 다른 지표보다 먼저 쓴다.
    /// 창 개수 같은 지표는 우연히 차이가 커 보일 수 있어, 큰 차이가 곧 정확함을 뜻하지 않는다.
    private static let preferredMetric = 6

    /// 고른 지표: 번호, 기준값, 열렸을 때 값이 더 큰지, 평소와 열림의 차이
    private struct Choice {
        let index: Int
        let threshold: Int
        let openIsHigher: Bool
        let gap: Int
        /// 어느 지표를 고를지 비교할 때 쓰는 점수
        var score: Int { gap + (index == MissionControlProbe.preferredMetric ? 100 : 0) }
    }

    private static func percentile(_ values: [Int], _ fraction: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[position]
    }

    /// 평소와 열림이 겹치지 않는 지표 중 차이가 가장 큰 것을 고른다.
    private var choice: Choice? {
        guard quiet[0].count >= 10, open[0].count >= 3 else { return nil }
        var best: Choice?
        for index in Self.metricNames.indices where !bannedMetrics.contains(index) {
            guard let quietHigh = Self.percentile(quiet[index], 0.9),
                  let quietLow = Self.percentile(quiet[index], 0.1),
                  let openMedian = Self.percentile(open[index], 0.5) else { continue }
            let candidate: Choice
            if openMedian > quietHigh {
                candidate = Choice(index: index,
                                   threshold: max(quietHigh + 1, quietHigh + (openMedian - quietHigh + 1) / 2),
                                   openIsHigher: true,
                                   gap: openMedian - quietHigh)
            } else if openMedian < quietLow {
                candidate = Choice(index: index,
                                   threshold: min(quietLow - 1, quietLow - (quietLow - openMedian + 1) / 2),
                                   openIsHigher: false,
                                   gap: quietLow - openMedian)
            } else {
                continue
            }
            if best == nil || candidate.score > best!.score { best = candidate }
        }
        return best
    }

    var isCalibrated: Bool { choice != nil }

    /// 제스처 없이 열림 자체를 알아채도 될 만큼 확실한가.
    /// 평소 값이 흔들리지 않고(같은 값만 나오고) 열림 표본도 충분해야 한다.
    var isStronglyCalibrated: Bool {
        guard let choice else { return false }
        guard open[choice.index].count >= 5, quiet[choice.index].count >= 20 else { return false }
        let low = Self.percentile(quiet[choice.index], 0.02)
        let high = Self.percentile(quiet[choice.index], 0.98)
        return low == high
    }

    // MARK: - 판정

    /// 지금 열려 있는 것으로 보이는가. 알 수 없으면 nil.
    func looksActive() -> Bool? {
        if notificationsWork { return openByNotification }
        guard let choice else { return nil }
        let values = Self.sample()
        lastValues = values
        let value = values[choice.index]
        return choice.openIsHigher ? value >= choice.threshold : value <= choice.threshold
    }

    /// 제스처 없이 "열렸다"고 단정해도 될 만큼 확실한가. 아니면 nil.
    func looksActiveStrict() -> Bool? {
        if notificationsWork { return openByNotification }
        guard isStronglyCalibrated else { return nil }
        return looksActive()
    }

    // MARK: - 진단

    var note: String {
        var lines: [String] = []
        lines.append("WindowServer 알림 등록: \(registerNote)")
        let lastEvent = lastNotification.map(String.init) ?? "없음"
        if notificationsWork {
            lines.append("알림 \(notificationCount)회 수신 (마지막 \(lastEvent)) → 이 신호만 사용, 지금 \(openByNotification ? "열림" : "닫힘")")
        } else {
            lines.append("열림 알림 없음 (수신 \(notificationCount)회, 마지막 \(lastEvent)) → 화면 지표로 판단")
        }
        let picked = choice
        if let picked {
            lines.append("고른 지표: \(Self.metricNames[picked.index]) "
                + "(\(picked.openIsHigher ? "열리면 증가" : "열리면 감소"), 기준 \(picked.threshold), 차이 \(picked.gap))"
                + (isStronglyCalibrated ? " / 열림 감지까지 가능" : " / 닫힘 확인만"))
        } else {
            lines.append("고른 지표: 없음 (평소와 열림이 구분되는 지표를 아직 못 찾음)")
        }
        if let distrustNote { lines.append("바로잡은 기록: \(distrustNote)") }
        if !bannedMetrics.isEmpty {
            lines.append("버린 지표: \(bannedMetrics.sorted().map { Self.metricNames[$0] }.joined(separator: ", "))")
        }
        lines.append("지표별 값 — 지금 / 평소(10~90%) / 열림(중앙값) / 표본 평소 \(quiet[0].count)개, 열림 \(open[0].count)개")
        for index in Self.metricNames.indices {
            let low = Self.percentile(quiet[index], 0.1).map(String.init) ?? "-"
            let high = Self.percentile(quiet[index], 0.9).map(String.init) ?? "-"
            let openMedian = Self.percentile(open[index], 0.5).map(String.init) ?? "-"
            let mark = picked?.index == index ? " ←" : ""
            lines.append("  \(Self.metricNames[index]): \(lastValues[index]) / \(low)~\(high) / \(openMedian)\(mark)")
        }
        return lines.joined(separator: "\n  ")
    }
}
