import Foundation

struct Space: Identifiable, Equatable, Hashable {
    /// CGS의 id64
    let id: CGSSpaceID
    /// 공간 고유 식별자. 이름은 이 값에 저장되어 순서를 바꿔도 따라간다.
    let uuid: String
    let displayID: String
    /// Mission Control이 붙이는 번호(데스크탑 N). 전체 화면 공간은 nil.
    let number: Int?
    let isFullscreen: Bool
    var isActive: Bool

    /// 이름이 없을 때 보여줄 기본 이름
    var defaultName: String {
        if let number { return "데스크탑 \(number)" }
        return "전체 화면 앱"
    }
}
