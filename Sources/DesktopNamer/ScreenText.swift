import AppKit
import CoreMedia
import ScreenCaptureKit
import Vision

/// 화면 위쪽을 실시간으로 받아 "데스크탑 N" 글자의 위치를 찾는다. Mission Control 내부 구조에 의존하지 않는다.
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
        /// 인식된 모든 글자의 화면 위치 (우리 이름표가 찍혔는지 판단용)
        let allFrames: [CGRect]
    }

    /// 캡처할 화면 위쪽 띠
    struct Strip {
        let screen: NSScreen
        let fraction: CGFloat

        var heightPoints: CGFloat { (screen.frame.height * fraction).rounded() }
        /// 띠 아래쪽의 AppKit y 좌표
        var bottomY: CGFloat { screen.frame.maxY - heightPoints }
        /// 디스플레이 기준(왼쪽 위 원점, 포인트) 캡처 영역
        var sourceRect: CGRect { CGRect(x: 0, y: 0, width: screen.frame.width, height: heightPoints) }
        var pixelSize: CGSize {
            CGSize(width: screen.frame.width * screen.backingScaleFactor, height: heightPoints * screen.backingScaleFactor)
        }

        /// AppKit y 중심 ± halfHeight 범위를 Vision의 관심 영역(정규화, 아래 원점)으로 바꾼다.
        func regionOfInterest(centerY: CGFloat, halfHeight: CGFloat) -> CGRect {
            let minY = max(0, (centerY - halfHeight - bottomY) / heightPoints)
            let maxY = min(1, (centerY + halfHeight - bottomY) / heightPoints)
            guard maxY > minY else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
            return CGRect(x: 0, y: minY, width: 1, height: maxY - minY)
        }
    }

    static let fullRegion = CGRect(x: 0, y: 0, width: 1, height: 1)

    static var hasScreenCaptureAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenCaptureAccess() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// 프레임에서 "데스크탑 N" / "Desktop N" 글자를 찾아 화면 좌표로 돌려준다.
    static func recognizeDesktopLabels(in pixelBuffer: CVPixelBuffer, strip: Strip, regionOfInterest: CGRect) throws -> Result {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = false
        request.regionOfInterest = regionOfInterest
        // 라벨(13pt)보다 훨씬 작은 글자는 건너뛰어 속도를 높인다 (관심 영역 높이 대비 비율)
        request.minimumTextHeight = 0.02
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let scale = CGFloat(width) / strip.screen.frame.width
        let regex = try NSRegularExpression(pattern: "^(데스크탑|Desktop)\\s*(\\d+)$")

        var labels: [Label] = []
        var allText: [String] = []
        var allFrames: [CGRect] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            // 관심 영역 기준 정규화 좌표 → 이미지 픽셀 좌표(아래 원점) → 화면 좌표
            let pixelRect = VNImageRectForNormalizedRectUsingRegionOfInterest(observation.boundingBox, width, height, regionOfInterest)
            let frame = CGRect(
                x: strip.screen.frame.minX + pixelRect.minX / scale,
                y: strip.bottomY + pixelRect.minY / scale,
                width: pixelRect.width / scale,
                height: pixelRect.height / scale
            )
            allText.append(text)
            allFrames.append(frame)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let numberRange = Range(match.range(at: 2), in: text),
                  let number = Int(text[numberRange]) else { continue }
            labels.append(Label(number: number, frame: frame, text: text))
        }
        return Result(labels: filterAlignedRow(labels), allText: allText, allFrames: allFrames)
    }

    /// Mission Control 라벨은 같은 높이에 나란히 놓인다. 같은 높이(±8pt)에 2개 이상 모인 그룹 중 가장 큰 것만 남긴다.
    /// 채팅 글 등 화면 다른 곳의 "데스크탑 N" 글자를 걸러낸다.
    private static func filterAlignedRow(_ labels: [Label]) -> [Label] {
        guard labels.count >= 2 else { return [] }
        var best: [Label] = []
        for anchor in labels {
            let row = labels.filter { abs($0.frame.midY - anchor.frame.midY) <= 8 }
            if row.count > best.count { best = row }
        }
        guard best.count >= 2 else { return [] }
        var seen = Set<Int>()
        return best.sorted { $0.frame.minX < $1.frame.minX }.filter { seen.insert($0.number).inserted }
    }
}

/// ScreenCaptureKit 스트림. 화면 위쪽 띠가 바뀔 때마다 프레임을 넘겨준다 (바뀌지 않으면 프레임이 오지 않는다).
final class ScreenStream: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "DesktopNamer.ScreenStream", qos: .userInteractive)

    /// 스트림 큐에서 호출된다.
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onStop: ((Error) -> Void)?

    var isRunning: Bool { stream != nil }

    /// 프레임 처리와 같은 큐에서 실행한다 (큐에서 읽는 상태를 안전하게 바꿀 때 사용)
    func perform(_ block: @escaping () -> Void) {
        queue.async(execute: block)
    }

    func start(strip: ScreenText.Strip) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = strip.screen.deviceDescription[key] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
            throw NSError(domain: "ScreenStream", code: 1, userInfo: [NSLocalizedDescriptionKey: "디스플레이를 찾지 못함"])
        }
        // 우리 이름표 창은 캡처에서 제외한다
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.sourceRect = strip.sourceRect
        config.width = Int(strip.pixelSize.width)
        config.height = Int(strip.pixelSize.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        self.display = display
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        stream.stopCapture { _ in }
    }

    private var display: SCDisplay?
    private(set) var excludedNote = "없음"

    /// 지정한 창(우리 이름표)들을 캡처에서 제외하도록 필터를 갱신한다.
    func excludeWindows(ids: Set<CGWindowID>) async {
        guard let stream, let display else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let ownBundle = Bundle.main.bundleIdentifier
            let windows = content.windows.filter {
                ids.contains($0.windowID) || $0.owningApplication?.bundleIdentifier == ownBundle
            }
            let filter = SCContentFilter(display: display, excludingWindows: windows)
            try await stream.updateContentFilter(filter)
            excludedNote = "\(windows.count)개 제외 (요청 \(ids.count)개)"
        } catch {
            excludedNote = "제외 갱신 실패: \(error.localizedDescription)"
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRaw = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw), status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop?(error)
    }
}
