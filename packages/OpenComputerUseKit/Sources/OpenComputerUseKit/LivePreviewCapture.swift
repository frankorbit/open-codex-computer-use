import CoreImage
import OSLog
import ScreenCaptureKit

enum LivePreviewCapture {
    /// ScreenCaptureKit 的 backgroundColor 不持有 CGColor，需覆盖整个采集生命周期。
    private static let blackBackground = CGColor(gray: 0, alpha: 1)
    private static let transparentBackground = CGColor(gray: 0, alpha: 0)

    static func configuration(for size: CGSize, transparent: Bool = false) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = min(2, 960 / max(size.width, size.height))
        config.width = max(1, Int(size.width * scale))
        config.height = max(1, Int(size.height * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = true
        config.preservesAspectRatio = false
        // 弹层的圆角、阴影空隙和不可见区域必须保留 alpha，不能烧成黑色再叠到 root。
        config.backgroundColor = transparent ? transparentBackground : blackBackground
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.shouldBeOpaque = false
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        return config
    }

    static func makeStream(for window: SCWindow) throws -> (SCStream, AsyncStream<PreviewFrameEvent>) {
        // 只镜像已绑定窗口，即使被其他 App 遮住也不把遮挡者的内容带入预览。
        let events = AsyncStream<PreviewFrameEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let sink = PreviewFrameSink(continuation: events.continuation)
        let stream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration(for: window.frame.size),
            delegate: sink
        )
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "ocu.preview.frames"))
        return (stream, events.stream)
    }

    static func currentBounds(
        _ target: LivePreviewTarget,
        readWindowInfo: (CGWindowListOption, CGWindowID) -> [[String: Any]]? = {
            CGWindowListCopyWindowInfo($0, $1) as? [[String: Any]]
        }
    ) -> CGRect? {
        // root 可位于其他 Space 或隐藏；可见性仅约束额外采集的 popup。
        guard let rows = readWindowInfo(.optionIncludingWindow, target.windowID),
              let row = rows.first(where: {
                  ($0[kCGWindowNumber as String] as? UInt32) == target.windowID &&
                      ($0[kCGWindowOwnerPID as String] as? Int32) == target.pid
              }), let dictionary = row[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary)
        else {
            return nil
        }
        return LivePreviewTarget(pid: target.pid, windowID: target.windowID, bounds: bounds)?.bounds
    }
}

// MARK: - PreviewFrameEvent

enum PreviewFrameEvent {
    case frame(CGImage)
    case transient
    case unavailable
    case stopped
    case stoppedByUser
}

// MARK: - PreviewFrameSink

/// 像素只保留最新一帧，慢 UI 不积压、不阻塞输入线程。
final class PreviewFrameSink: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    private let continuation: AsyncStream<PreviewFrameEvent>.Continuation
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()

    init(continuation: AsyncStream<PreviewFrameEvent>.Continuation) {
        self.continuation = continuation
    }

    func stream(_: SCStream, didStopWithError error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        continuation
            .yield((error as NSError).code == SCStreamError.Code.userStopped.rawValue ? .stoppedByUser : .stopped)
        continuation.finish()
    }

    func stream(_: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sample,
                  createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status != SCFrameStatus.idle.rawValue
        else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        switch Self.disposition(for: status) {
        case .ignore: return
        case .transient:
            Logger(subsystem: "ai.today.ocu", category: "preview").debug("capture_frame_transient status=\(status)")
            continuation.yield(.transient)
            return
        case .unavailable:
            Logger(subsystem: "ai.today.ocu", category: "preview").debug("capture_frame_unavailable status=\(status)")
            continuation.yield(.unavailable)
            return
        case .decode: break
        }
        guard let buffer = sample.imageBuffer,
              let image = context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(
                  x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)
              ))
        else {
            continuation.yield(.transient)
            return
        }
        continuation.yield(.frame(image))
    }

    enum Disposition {
        case ignore, decode, transient, unavailable
    }

    static func disposition(for status: Int) -> Disposition {
        switch SCFrameStatus(rawValue: status) {
        case .idle: .ignore
        case .complete: .decode
        case .started: .transient
        // 空白、挂起、停止及未知状态立即撤掉旧画面，不掩盖共享停止。
        default: .unavailable
        }
    }
}
