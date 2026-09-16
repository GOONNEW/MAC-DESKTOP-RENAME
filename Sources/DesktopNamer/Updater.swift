import AppKit

/// 앱 안에서 최신 코드를 내려받아 빌드하고 새 버전으로 재시작한다.
final class Updater {
    /// 프로젝트 폴더. 앱 번들이 <프로젝트>/build/DesktopNamer.app 안에 있다고 보고 거슬러 올라간다.
    static var projectDirectory: URL? {
        let bundle = URL(fileURLWithPath: Bundle.main.bundlePath)
        let candidate = bundle.deletingLastPathComponent().deletingLastPathComponent()
        let script = candidate.appendingPathComponent("scripts/update.sh")
        return FileManager.default.isExecutableFile(atPath: script.path) ? candidate : nil
    }

    static var canUpdate: Bool { projectDirectory != nil }

    private let window = UpdateWindowController()
    private var process: Process?
    private var cancelled = false

    /// 업데이트를 시작한다. 진행 창이 뜨고, 끝나면 새 버전으로 재시작할 수 있다.
    func start() {
        guard let directory = Updater.projectDirectory else {
            let alert = NSAlert()
            alert.messageText = "업데이트를 시작하지 못했습니다"
            alert.informativeText = "프로젝트 폴더를 찾지 못했습니다.\n앱이 <프로젝트>/build/DesktopNamer.app 위치에 있어야 합니다."
            alert.addButton(withTitle: "확인")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }

        cancelled = false
        window.show { [weak self] in
            self?.cancelled = true
            self?.process?.terminate()
        }
        window.setProgress(0.05, status: "최신 코드를 내려받는 중…")
        run(in: directory)
    }

    private func run(in directory: URL) {
        // 앱을 종료하지 않고 빌드만 한다. 빌드 결과는 새로 실행할 때 적용된다.
        let script = """
        set -o pipefail
        cd "\(directory.path)" || exit 1
        ./scripts/update-build.sh
        """

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
            DispatchQueue.main.async { self?.handleFinish(code: finished.terminationStatus) }
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
            } else if trimmed.hasPrefix("[") , let slash = trimmed.firstIndex(of: "/") {
                // "[7 / 8] ..." 형태의 진행 표시
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

    private func handleFinish(code: Int32) {
        process = nil
        if cancelled {
            window.close()
            return
        }
        guard code == 0 else {
            window.finish(success: false, message: "빌드에 실패했습니다. 아래 내용을 복사해서 알려주세요.") {}
            return
        }
        window.setProgress(1, status: "새 버전이 준비되었습니다.")
        window.finish(success: true, message: "앱을 다시 시작하면 새 버전이 적용됩니다.") {
            Updater.relaunch()
        }
    }

    /// 앱을 종료하고 새로 실행한다
    private static func relaunch() {
        guard let directory = projectDirectory else { return }
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
}
