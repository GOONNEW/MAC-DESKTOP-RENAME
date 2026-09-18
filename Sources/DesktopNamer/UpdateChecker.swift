import AppKit

/// 새 버전이 올라왔는지 확인한다.
///
/// 이 앱은 버전 번호를 올리지 않고 브랜치의 최신 코드를 그대로 받아 쓴다.
/// 그래서 버전 문자열을 비교하는 대신 이렇게 판단한다.
///   GitHub 브랜치의 마지막 커밋 시각  >  지금 앱이 만들어진 시각
/// 앱을 새로 빌드하거나 설치하면 실행 파일의 시각이 그때로 갱신되므로,
/// 업데이트를 마치면 자동으로 "최신"이 된다.
final class UpdateChecker {
    private static let owner = "GOONNEW"
    private static let repo = "MAC-DESKTOP-RENAME"
    /// 업데이트를 받아 오는 브랜치 (scripts/update-build.sh와 같아야 한다)
    private static let branch = "claude/determined-heisenberg-04924x"

    private(set) var updateAvailable = false
    private(set) var note = "아직 확인하지 않음"
    private(set) var lastCheckedAt: Date?
    private(set) var latestCommitTitle: String?

    private var checking = false
    /// 메뉴를 열 때 다시 묻기까지의 최소 간격.
    ///
    /// 짧게 잡아야 한다. 길게 잡으면 새 버전이 올라와도 한참 동안 메뉴에 나타나지
    /// 않는다. (3시간으로 두었더니 업데이트 항목이 계속 보이지 않았다)
    /// 확인은 가벼운 요청 하나이고, GitHub은 시간당 60번까지 허용한다.
    private let interval: TimeInterval = 60

    /// 지금 실행 중인 앱이 만들어진 시각
    static var builtAt: Date? {
        guard let url = Bundle.main.executableURL,
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else { return nil }
        return values.contentModificationDate
    }

    /// 오래됐으면 다시 확인한다 (메뉴를 열 때마다 불러도 된다)
    func checkIfStale() {
        if let lastCheckedAt, Date().timeIntervalSince(lastCheckedAt) < interval { return }
        check()
    }

    /// - Parameter completion: 확인이 끝나면 호출된다. 메인 스레드.
    func check(completion: ((Bool) -> Void)? = nil) {
        guard !checking else { completion?(updateAvailable); return }
        guard var components = URLComponents(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/commits") else {
            finish(available: false, note: "주소를 만들 수 없음", completion: completion)
            return
        }
        // 브랜치 이름에 /가 들어 있어 경로가 아니라 질의 문자열로 넘긴다
        components.queryItems = [
            URLQueryItem(name: "sha", value: Self.branch),
            URLQueryItem(name: "per_page", value: "1"),
        ]
        guard let url = components.url else {
            finish(available: false, note: "주소를 만들 수 없음", completion: completion)
            return
        }

        checking = true
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        // 중간 캐시가 오래된 답을 주지 않도록
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.finish(available: false, note: "확인 실패: \(error.localizedDescription)", completion: completion)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data else {
                self.finish(available: false, note: "확인 실패 (응답 \(status))", completion: completion)
                return
            }
            guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = list.first,
                  let commit = first["commit"] as? [String: Any],
                  let author = (commit["committer"] as? [String: Any]) ?? (commit["author"] as? [String: Any]),
                  let dateText = author["date"] as? String,
                  let commitDate = ISO8601DateFormatter().date(from: dateText) else {
                self.finish(available: false, note: "응답을 읽지 못했습니다", completion: completion)
                return
            }
            let title = (commit["message"] as? String)?
                .split(separator: "\n").first
                .map(String.init)

            guard let builtAt = Self.builtAt else {
                self.finish(available: false, note: "앱이 만들어진 시각을 알 수 없음 (최신 커밋 \(commitDate))",
                            title: title, completion: completion)
                return
            }
            // 빌드 직후 시각이 커밋보다 몇 초 빠른 경우가 있어 여유를 둔다
            let available = commitDate.timeIntervalSince(builtAt) > 120
            let formatter = DateFormatter()
            formatter.dateFormat = "M월 d일 HH:mm"
            let note = available
                ? "새 버전 있음 (최신 커밋 \(formatter.string(from: commitDate)), 내 앱 \(formatter.string(from: builtAt)))"
                : "최신 버전입니다 (내 앱 \(formatter.string(from: builtAt)))"
            self.finish(available: available, note: note, title: title, completion: completion)
        }.resume()
    }

    private func finish(available: Bool, note: String, title: String? = nil,
                        completion: ((Bool) -> Void)?) {
        DispatchQueue.main.async {
            self.checking = false
            self.updateAvailable = available
            self.note = note
            self.lastCheckedAt = Date()
            if let title { self.latestCommitTitle = title }
            completion?(available)
        }
    }
}
