import CoreImage
import ScreenCaptureKit

enum LivePreviewCapture {
    /// ScreenCaptureKit 的 backgroundColor 不持有 CGColor，需覆盖整个采集生命周期。
    private static let blackBackground = CGColor(gray: 0, alpha: 1)

    static func configuration(for size: CGSize) -> SCStreamConfiguration {
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
        config.backgroundColor = blackBackground
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        return config
    }

    static func currentBounds(_ target: LivePreviewTarget) -> CGRect? {
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, target.windowID) as? [[String: Any]],
              let row = rows.first(where: {
                  ($0[kCGWindowNumber as String] as? UInt32) == target.windowID &&
                      ($0[kCGWindowOwnerPID as String] as? Int32) == target.pid
              }), let bounds = row[kCGWindowBounds as String] as? NSDictionary
        else {
            return nil
        }
        return CGRect(dictionaryRepresentation: bounds)
    }
}

// MARK: - PreviewFrameEvent

enum PreviewFrameEvent {
    case frame(CGImage)
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
        guard status == SCFrameStatus.complete.rawValue, let buffer = sample.imageBuffer,
              let image = context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(
                  x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)
              ))
        else {
            continuation.yield(.unavailable)
            return
        }
        continuation.yield(.frame(image))
    }
}
