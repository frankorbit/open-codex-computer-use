import AppKit
@testable import OpenComputerUseKit
import ScreenCaptureKit
import Testing

struct LivePreviewCaptureLifetimeTests {
    @Test func `capture session retains receiver after factory returns and delivers first frame`() async throws {
        var session: LivePreviewCaptureSession? = try LivePreviewCapture.makeStream(
            filter: SCContentFilter(), size: CGSize(width: 16, height: 16)
        )
        weak var receiver = session?.sink
        try #require(receiver != nil)
        await Task.yield()
        try #require(receiver != nil)
        let events = try #require(session?.events)
        let sample = try makeFrame()
        // 不启动系统录屏；通过真实接收器、解码和 AsyncStream 验证工厂返回后的首帧通路。
        try session?.sink.stream(#require(session?.stream), didOutputSampleBuffer: sample, of: .screen)
        for await event in events {
            guard case let .frame(image) = event else {
                Issue.record("首帧未送达")
                return
            }
            #expect(image.width == 16 && image.height == 16)
            break
        }
        session = nil
        #expect(receiver == nil)
    }

    @Test func `replacing session keeps only the new receiver alive`() throws {
        var previous: LivePreviewCaptureSession? = try LivePreviewCapture.makeStream(
            filter: SCContentFilter(), size: CGSize(width: 16, height: 16)
        )
        weak var oldReceiver = previous?.sink
        var current: LivePreviewCaptureSession? = try LivePreviewCapture.makeStream(
            filter: SCContentFilter(), size: CGSize(width: 20, height: 20)
        )
        weak var newReceiver = current?.sink
        previous = nil
        #expect(oldReceiver == nil)
        #expect(newReceiver != nil)
        current = nil
        #expect(newReceiver == nil)
    }

    @MainActor
    @Test func `loading message is centered horizontally and vertically`() throws {
        for size in [CGSize(width: 360, height: 240), CGSize(width: 230, height: 408)] {
            let view = LivePreviewView(frame: CGRect(origin: .zero, size: size))
            let context = try #require(CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            view.draw(view.bounds)
            let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            var pixels = CGRect.null
            for pixelY in 0 ..< context.height {
                for pixelX in 0 ..< context.width {
                    let offset = pixelY * context.bytesPerRow + pixelX * 4
                    if max(bytes[offset], bytes[offset + 1], bytes[offset + 2]) > 25 {
                        pixels = pixels.union(CGRect(x: pixelX, y: pixelY, width: 1, height: 1))
                    }
                }
            }
            #expect(!pixels.isNull)
            #expect(abs(pixels.midX - size.width / 2) <= 3)
            #expect(abs(pixels.midY - size.height / 2) <= 3)
        }
    }

    private func makeFrame() throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                                    nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                             imageBuffer: pixels, formatDescriptionOut: &format) ==
                noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(try CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescription: #require(format),
            sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr)
        let frame = try #require(sample)
        let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(frame, createIfNecessary: true)
            as? [NSMutableDictionary])
        try #require(attachments.first)[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
        return frame
    }
}
