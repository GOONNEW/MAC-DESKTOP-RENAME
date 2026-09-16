import AppKit

/// 최신 버전으로 업데이트한다.
///
/// 두 가지 경로를 지원한다.
/// - 프로젝트 폴더 안에서 실행 중이면: 소스를 내려받아 직접 빌드한다 (개발용).
/// - 응용 프로그램 등 다른 위치면: GitHub에 올라온 완성본(DMG)을 내려받아 앱을 교체한다 (설치본용).
final class Updater {
    /// 완성본을 받는 곳
    private static let releaseURL = URL(string: "https://github.com/GOONNEW/MAC-DESKTOP-RENAME/releases/latest/download/DesktopNamer.dmg")!

    /// 프로젝트 폴더. 앱 번들이 <프로젝트>/build/DesktopNamer.app 안에 있을 때만 값이 있다.
    static var projectDirectory: URL? {
        let bundle = URL(fileURLWithPath: Bundle.main.bundlePath)
        let candidate = bundle.deletingLastPathComponent().deletingLastPathComponent()
        let script = candidate.appendingPathComponent("scripts/update.sh")
        return FileManager.default.isExecutableFile(atPath: script.path) ? candidate : nil
    }

    /// 어디서 실행되든 업데이트할 수 있다
    static var canUpdate: Bool { true }

    private let window = UpdateWindowController()
    private var process: Process?
    private var task: URLSessionDownloadTask?
    private var cancelled = false

    func start() {
        cancelled = false
        window.show { [weak self] in
            self?.cancelled = true
            self?.process?.terminate()
            self?.task?.cancel()
        }
        if let directory = Updater.projectDirectory {
            window.setProgress(0.05, status: "최신 코드를 내려받는 중…")
            buildFromSource(in: directory)
        } else {
            window.setProgress(0.05, status: "최신 버전을 확인하는 중…")
            downloadRelease()
        }
    }

    // MARK: - 설치본: 완성본 내려받아 교체

    private func downloadRelease() {
        let session = URLSession(configuration: .default)
        let task = session.downloadTask(with: Updater.releaseURL) { [weak self] location, response, error in
            guard let self else { return }
            if self.cancelled { return }
            if let error {
                DispatchQueue.main.async {
                    self.window.finish(success: false, message: "내려받기 실패: \(error.localizedDescription)") {}
                }
                return
            }
            guard let location,
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                DispatchQueue.main.async {
                    self.window.appendLog("응답: \((response as? HTTPURLResponse)?.statusCode.description ?? "없음")\n")
                    self.window.finish(success: false, message: "아직 배포된 최신 버전이 없습니다.") {}
                }
                return
            }
            // 임시 파일은 곧 사라지므로 옮겨 둔다
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("DesktopNamer-update-\(UUID().uuidString.prefix(8)).dmg")
            do {
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                DispatchQueue.main.async {
                    self.window.finish(success: false, message: "파일 저장 실패: \(error.localizedDescription)") {}
                }
                return
            }
            DispatchQueue.main.async { self.installDMG(at: destination) }
        }
        self.task = task

        // 진행률 표시
        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.window.setProgress(0.05 + 0.75 * progress.fractionCompleted,
                                         status: "새 버전을 내려받는 중… \(Int(progress.fractionCompleted * 100))%")
            }
        }
        progressObservation = observation
        task.resume()
    }

    private var progressObservation: NSKeyValueObservation?

    /// DMG를 열어 앱을 현재 위치에 덮어쓴다
    private func installDMG(at dmg: URL) {
        window.setProgress(0.85, status: "설치하는 중…")
        let appPath = Bundle.main.bundlePath
        let script = """
        set -e
        MOUNT="$(mktemp -d)"
        hdiutil attach "\(dmg.path)" -nobrowse -quiet -mountpoint "$MOUNT"
        trap 'hdiutil detach "$MOUNT" -quiet || true; rm -rf "$MOUNT" "\(dmg.path)"' EXIT
        SRC="$MOUNT/DesktopNamer.app"
        [ -d "$SRC" ] || { echo "DMG 안에서 앱을 찾지 못했습니다"; exit 1; }
        # 실행 중인 앱을 교체하므로, 먼저 옆에 복사한 뒤 바꿔치기한다
        rm -rf "\(appPath).new"
        cp -R "$SRC" "\(appPath).new"
        echo "설치 준비 완료"
        """
        run(script: script) { [weak self] code in
            guard let self else { return }
            guard code == 0 else {
                self.window.finish(success: false, message: "설치에 실패했습니다. 아래 내용을 확인해 주세요.") {}
                return
            }
            self.window.setProgress(1, status: "새 버전이 준비되었습니다.")
            self.window.finish(success: true, message: "앱을 다시 시작하면 새 버전이 적용됩니다.") {
                Updater.swapAndRelaunch(appPath: appPath)
            }
        }
    }

    /// 앱을 종료한 뒤 새 버전으로 바꿔치기하고 다시 연다
    private static func swapAndRelaunch(appPath: String) {
        let script = """
        for _ in {1..40}; do
          pgrep -x DesktopNamer >/dev/null || break
          sleep 0.25
        done
        rm -rf "\(appPath).old"
        mv "\(appPath)" "\(appPath).old" 2>/dev/null || true
        mv "\(appPath).new" "\(appPath)"
        rm -rf "\(appPath).old"
        xattr -dr com.apple.quarantine "\(appPath)" 2>/dev/null || true
        open "\(appPath)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", script]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: - 개발용: 소스에서 빌드

    private func buildFromSource(in directory: URL) {
        let script = """
        set -o pipefail
        cd "\(directory.path)" || exit 1
        ./scripts/update-build.sh
        """
        run(script: script) { [weak self] code in
            guard let self else { return }
            guard code == 0 else {
                self.window.finish(success: false, message: "빌드에 실패했습니다. 아래 내용을 복사해서 알려주세요.") {}
                return
            }
            self.window.setProgress(1, status: "새 버전이 준비되었습니다.")
            self.window.finish(success: true, message: "앱을 다시 시작하면 새 버전이 적용됩니다.") {
                Updater.relaunchFromProject(directory: directory)
            }
        }
    }

    private static func relaunchFromProject(directory: URL) {
        let app = directory.appendingPathComponent("build/DesktopNamer.app")
        let script = """
        for _ in {1..40}; do
          pgrep -x DesktopNamer >/dev/null || break
          sleep 0.25
        done
        open "\(app.path)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", script]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: - 공통

    private func run(script: String, completion: @escaping (Int32) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        self.process = process

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.handleOutput(text) }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.process = nil
                guard self?.cancelled != true else {
                    self?.window.close()
                    return
                }
                completion(finished.terminationStatus)
            }
        }
        do {
            try process.run()
        } catch {
            window.finish(success: false, message: "실행 실패: \(error.localizedDescription)") {}
        }
    }

    /// 빌드 출력에서 진행 단계를 읽어 막대를 움직인다
    private func handleOutput(_ text: String) {
        window.appendLog(text)
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("최신 코드") {
                window.setProgress(0.15, status: "최신 코드를 내려받는 중…")
            } else if trimmed.contains("Compiling") || trimmed.contains("Building") {
                window.setProgress(0.5, status: "빌드하는 중…")
            } else if trimmed.hasPrefix("["), let slash = trimmed.firstIndex(of: "/") {
                let done = Int(trimmed.dropFirst().prefix(while: { $0.isNumber }).trimmingCharacters(in: .whitespaces)) ?? 0
                let totalText = trimmed[trimmed.index(after: slash)...].prefix(while: { $0.isNumber || $0 == " " })
                let total = Int(totalText.trimmingCharacters(in: .whitespaces)) ?? 0
                if total > 0 {
                    window.setProgress(0.4 + 0.5 * Double(done) / Double(total), status: "빌드하는 중… (\(done)/\(total))")
                }
            } else if trimmed.contains("Build complete") || trimmed.contains("빌드 완료") {
                window.setProgress(0.95, status: "마무리하는 중…")
            }
        }
    }
}
