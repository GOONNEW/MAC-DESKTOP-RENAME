import AppKit
import ScreenCaptureKit
import Vision

/// 화면 위쪽을 찍어 "데스크탑 N" 글자의 위치를 찾는다. Mission Control 내부 구조에 의존하지 않는다.
enum ScreenText {
    struct Label {
        let number: Int
        /// AppKit 좌표(왼쪽 아래 원점)의 글자 영역
        let frame: CGRect
        let text: String
    }

    struct Result {
        let labels: [Label]
        /// 인식된 모든 글자 (진단용)
        let allText: [String]
    }

    static var hasScreenCaptureAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenCaptureAccess() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// 화면 위쪽 `fraction` 비율만큼을 캡처한다. 이 앱의 창은 제외한다.
    static func captureTopStrip(of screen: NSScreen, fraction: CGFloat) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
            throw NSError(domain: "ScreenText", code: 1, userInfo: [NSLocalizedDescriptionKey: "디스플레이를 찾지 못함"])
        }
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        let stripHeight = (screen.frame.height * fraction).rounded()
        config.sourceRect = CGRect(x: 0, y: 0, width: screen.frame.width, height: stripHeight)
        config.width = Int(screen.frame.width * scale)
        config.height = Int(stripHeight * scale)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// 캡처 이미지에서 "데스크탑 N" / "Desktop N" 글자를 찾아 화면 좌표로 돌려준다.
    static func recognizeDesktopLabels(in image: CGImage, screen: NSScreen, fraction: CGFloat) throws -> Result {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let stripHeight = (screen.frame.height * fraction).rounded()
        let stripBottom = screen.frame.maxY - stripHeight
        let regex = try NSRegularExpression(pattern: "^(데스크탑|Desktop)\\s*(\\d+)$")

        var labels: [Label] = []
        var allText: [String] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            allText.append(text)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let numberRange = Range(match.range(at: 2), in: text),
                  let number = Int(text[numberRange]) else { continue }
            let box = observation.boundingBox
            let frame = CGRect(
                x: screen.frame.minX + box.minX * screen.frame.width,
                y: stripBottom + box.minY * stripHeight,
                width: box.width * screen.frame.width,
                height: box.height * stripHeight
            )
            labels.append(Label(number: number, frame: frame, text: text))
        }
        return Result(labels: labels, allText: allText)
    }
}
