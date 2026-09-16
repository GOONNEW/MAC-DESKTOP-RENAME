import Foundation
import Combine

/// 공간 UUID → 사용자 지정 이름. UserDefaults에 저장한다.
final class NameStore: ObservableObject {
    private static let key = "spaceNames"

    @Published private(set) var names: [String: String] {
        didSet { UserDefaults.standard.set(names, forKey: Self.key) }
    }

    init() {
        names = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    func customName(for space: Space) -> String? {
        guard let name = names[space.uuid]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    /// 사용자 지정 이름이 있으면 그것, 없으면 기본 이름(데스크탑 N)
    func displayName(for space: Space) -> String {
        customName(for: space) ?? space.defaultName
    }

    func setName(_ name: String, for space: Space) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            names.removeValue(forKey: space.uuid)
        } else {
            names[space.uuid] = trimmed
        }
    }

    /// 현재 존재하는 공간의 이름만 남긴다.
    func prune(keeping uuids: [String]) {
        let keep = Set(uuids)
        let pruned = names.filter { keep.contains($0.key) }
        if pruned.count != names.count { names = pruned }
    }
}
