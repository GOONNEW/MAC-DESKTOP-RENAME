import AppKit
import CoreGraphics

/// Mission Control이 "정말로" 열려 있는지 확인한다.
///
/// macOS에는 Mission Control 상태를 알려주는 공개 API가 없다. 그래서 지금까지는
/// 제스처로 열림을, 클릭/키 입력으로 닫힘을 추측했는데 자주 어긋났다.
/// (구경하는 도중에 이름이 꺼지거나, 닫았는데 이름이 남는 문제)
///
/// 대신 이 클래스는 관찰로 판단한다. Mission Control이 켜지면 Dock 프로세스가 화면 위에
/// 창을 몇 개 더 만든다. 몇 개가 늘어나는지는 macOS 버전과 모니터 수에 따라 다르므로
/// 숫자를 미리 정해 두지 않고 실제로 재서 배운다.
///
/// - 평소 화면일 때 본 개수 중 가장 작은 값을 기준선으로 삼는다.
/// - 열렸다고 판단한 직후에 본 개수를 열림 표본으로 삼는다.
/// - 열림 표본이 기준선보다 크면 "보정 완료". 그 뒤로는 개수만 보고 판단한다.
///
/// 이 macOS에서 개수가 달라지지 않으면 보정이 끝나지 않고, 그때는 `looksActive()`가
/// nil(모름)을 돌려준다. 호출하는 쪽은 예전처럼 제스처와 입력으로만 판단하면 되므로
/// 상황이 나빠지는 일은 없다.
final class MissionControlProbe {
    /// 평소 화면에서 관찰한 Dock 창 개수들 (오래된 것부터 밀려난다)
    private var quietCounts: [Int] = []
    /// Mission Control이 열렸을 때 관찰한 Dock 창 개수들
    private var openCounts: [Int] = []
    private(set) var lastCount = 0

    /// 최근 표본의 중앙값을 쓴다. 평균이나 최솟값과 달리 이상한 표본 하나에 휘둘리지 않고,
    /// 오래된 표본이 밀려나므로 환경이 바뀌면 스스로 다시 배운다.
    var quietBaseline: Int? { Self.median(quietCounts) }
    var openSample: Int? { Self.median(openCounts) }

    private static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// 배운 값만으로 "지금 열려 있나"를 판단할 수 있는 상태인가
    var isCalibrated: Bool {
        guard let quietBaseline, let openSample else { return false }
        return openSample > quietBaseline && quietCounts.count >= 3
    }

    /// 제스처 없이 열림 자체를 알아채도 될 만큼 차이가 뚜렷한가.
    ///
    /// Dock 아이콘 우클릭 메뉴처럼 창이 하나 늘어나는 경우와 헷갈리면
    /// 평소 화면에 큰 글씨가 떠 버린다. 그래서 여는 쪽은 더 엄격하게 본다.
    var isStronglyCalibrated: Bool {
        guard let quietBaseline, let openSample else { return false }
        return openSample - quietBaseline >= 2 && openCounts.count >= 3 && quietCounts.count >= 5
    }

    /// "열렸다"로 인정할 창 개수. 평소와 열림의 중간쯤으로 잡아 잡음을 피한다.
    private var threshold: Int? {
        guard let quietBaseline, let openSample, openSample > quietBaseline else { return nil }
        return max(quietBaseline + 1, quietBaseline + (openSample - quietBaseline + 1) / 2)
    }

    /// 지금 화면 위에 떠 있는 Dock 소유 창의 개수.
    ///
    /// 창 "제목"을 읽지 않으므로 화면 기록 권한이 필요 없다.
    /// `.excludeDesktopElements`로 바탕화면 그림과 아이콘 창은 빼서, 평소 개수가 안정적이다.
    static func dockWindowCount() -> Int {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return 0 }
        var total = 0
        for info in list where (info[kCGWindowOwnerName as String] as? String) == "Dock" {
            total += 1
        }
        return total
    }

    /// 평소 화면이라고 확신할 때 부른다
    func noteQuiet() {
        let count = Self.dockWindowCount()
        lastCount = count
        quietCounts.append(count)
        if quietCounts.count > 40 { quietCounts.removeFirst(quietCounts.count - 40) }
    }

    /// Mission Control이 열렸다고 판단한 직후에 부른다
    func noteOpen() {
        let count = Self.dockWindowCount()
        lastCount = count
        openCounts.append(count)
        if openCounts.count > 12 { openCounts.removeFirst(openCounts.count - 12) }
    }

    /// 지금 열려 있는 것으로 보이는가. 아직 배우지 못했으면 nil(모름).
    func looksActive() -> Bool? {
        guard isCalibrated, let threshold else { return nil }
        let count = Self.dockWindowCount()
        lastCount = count
        return count >= threshold
    }

    /// 제스처 없이 "열렸다"고 단정해도 될 만큼 확실한가. 아니면 nil.
    func looksActiveStrict() -> Bool? {
        guard isStronglyCalibrated else { return nil }
        return looksActive()
    }

    /// 배운 값을 버리고 처음부터 다시 관찰한다
    func reset() {
        quietCounts.removeAll()
        openCounts.removeAll()
    }

    var note: String {
        let quiet = quietBaseline.map(String.init) ?? "-"
        let open = openSample.map(String.init) ?? "-"
        let state = isStronglyCalibrated ? "보정됨(열림 감지까지)"
            : isCalibrated ? "보정됨(닫힘 확인만)" : "보정 전 (제스처로만 판단)"
        let limit = threshold.map(String.init) ?? "-"
        return "Dock 창 지금 \(lastCount)개 / 평소 \(quiet) / 열림 \(open) / 기준 \(limit) / \(state)"
            + " / 표본 평소 \(quietCounts.count)개, 열림 \(openCounts.count)개"
    }
}
