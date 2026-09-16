import AppKit

/// 앱 안에서 최신 코드를 내려받아 빌드하고 새 버전으로 재시작한다.
/// 터미널에서 update.sh를 직접 치지 않아도 되게 한다.
enum Updater {
    /// 프로젝트 폴더. 앱 번들이 <프로젝트>/build/DesktopNamer.app 안에 있다고 보고 거슬러 올라간다.
    static var projectDirectory: URL? {
        let bundle = URL(fileURLWithPath: Bundle.main.bundlePath)
        let candidate = bundle.deletingLastPathComponent().deletingLastPathComponent()
        let script = candidate.appendingPathComponent("scripts/update.sh")
        return FileManager.default.isExecutableFile(atPath: script.path) ? candidate : nil
    }

    static var canUpdate: Bool { projectDirectory != nil }

    /// 터미널 창에서 업데이트를 실행한다. 빌드가 끝나면 앱이 다시 실행된다.
    /// 앱 자신을 덮어쓰는 작업이라 앱 안에서 직접 하면 중간에 죽을 수 있어, 별도 프로세스에 맡긴다.
    static func runUpdate() -> String? {
        guard let directory = projectDirectory else {
            return "프로젝트 폴더를 찾지 못했습니다.\n앱이 <프로젝트>/build/DesktopNamer.app 위치에 있어야 합니다."
        }

        // 업데이트를 수행할 임시 스크립트. 앱을 종료한 뒤 빌드하고 다시 실행한다.
        let script = """
        #!/bin/bash
        cd "\(directory.path)" || exit 1
        # 앱이 완전히 끝나기를 기다린다
        for _ in {1..40}; do
          pgrep -x DesktopNamer >/dev/null || break
          sleep 0.25
        done
        ./scripts/update.sh 2>&1 | tee /tmp/desktopnamer-update.log
        status=${PIPESTATUS[0]}
        if [ $status -eq 0 ]; then
          open "\(directory.path)/build/DesktopNamer.app"
          echo
          echo "업데이트 완료. 이 창은 닫아도 됩니다."
        else
          echo
          echo "업데이트 실패 (코드 $status). 아래 오류만 복사해서 알려주세요:"
          echo "----------------------------------------"
          grep -A 3 "error:" /tmp/desktopnamer-update.log | head -40
          echo "----------------------------------------"
        fi
        """

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("desktopnamer-update-\(UUID().uuidString.prefix(8)).command")
        do {
            try script.write(to: temporary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        } catch {
            return "업데이트 준비 실패: \(error.localizedDescription)"
        }

        // .command 파일을 열면 터미널에서 실행되고 진행 상황이 보인다
        NSWorkspace.shared.open(temporary)
        return nil
    }
}
