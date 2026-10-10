import AppKit
@testable import OpenComputerUseKit
import XCTest

final class SoftwareCursorGlyphStyleTests: XCTestCase {
    private let bounds = CGRect(origin: .zero, size: SoftwareCursorGlyphMetrics.windowSize)
    private let neutralState = SoftwareCursorGlyphRenderState(
        rotation: 0,
        cursorBodyOffset: .zero,
        fogOffset: .zero,
        fogOpacity: 0.12,
        fogScale: 1,
        clickProgress: 0
    )

    func testThemeIsOptInAndUnknownValuesKeepUpstream() {
        XCTAssertEqual(SoftwareCursorGlyphStyle.resolve(environment: [:]), .upstream)
        for value in ["", "default", "upstream", "unknown", "1"] {
            XCTAssertEqual(SoftwareCursorGlyphStyle.resolve(environment: [
                "OPEN_COMPUTER_USE_VISUAL_CURSOR_THEME": value
            ]), .upstream)
        }
        for value in ["today", "TODAY", " today\n"] {
            XCTAssertEqual(SoftwareCursorGlyphStyle.resolve(environment: [
                "OPEN_COMPUTER_USE_VISUAL_CURSOR_THEME": value
            ]), .today)
        }
    }

    func testBrandColorUsesSRGBAndSoftHalo() throws {
        let color = try XCTUnwrap(SoftwareCursorGlyphStyle.today.tintColor)
        XCTAssertEqual(color.colorSpace, .sRGB)
        XCTAssertEqual(color.redComponent, 0.01, accuracy: 0.000001)
        XCTAssertEqual(color.greenComponent, 0.66, accuracy: 0.000001)
        XCTAssertEqual(color.blueComponent, 0.96, accuracy: 0.000001)
        XCTAssertEqual(color.alphaComponent, 1)
        XCTAssertEqual(SoftwareCursorGlyphStyle.today.haloOpacity, 0.35)
        XCTAssertNil(SoftwareCursorGlyphStyle.upstream.tintColor)
        XCTAssertEqual(SoftwareCursorGlyphStyle.upstream.haloOpacity, 1)
    }

    func testReferenceSoftensHaloPreservesBodyAndDoesNotMutateSource() throws {
        let source = try makeBitmap(width: 5, height: 1)
        for (column, alpha) in [CGFloat(0), 0.4, 0.65, 0.775, 1].enumerated() {
            source.setFillColor(NSColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: alpha).cgColor)
            source.fill(CGRect(x: column, y: 0, width: 1, height: 1))
        }
        let image = try NSImage(cgImage: XCTUnwrap(source.makeImage()), size: CGSize(width: 5, height: 1))
        XCTAssertTrue(SoftwareCursorGlyphStyle.upstream.makeReferenceArtwork(from: image) === image)
        let before = try imageBytes(image)
        let softened = try XCTUnwrap(SoftwareCursorGlyphStyle.today.makeReferenceArtwork(from: image))
        XCTAssertEqual(softened.size, image.size)
        let after = try imageBytes(softened)
        XCTAssertEqual(after[3], 0)
        XCTAssertEqual(Double(after[7]) / Double(before[7]), 0.35, accuracy: 0.01)
        XCTAssertEqual(Double(after[11]) / Double(before[11]), 0.35, accuracy: 0.01)
        XCTAssertEqual(Double(after[15]) / Double(before[15]), 0.675, accuracy: 0.02)
        XCTAssertEqual(after[19], before[19])
        for offset in stride(from: 0, to: after.count, by: 4) {
            XCTAssertLessThanOrEqual(after[offset], after[offset + 3])
        }
        XCTAssertEqual(try imageBytes(image), before)
    }

    func testReferenceTintPreservesAlphaAndDoesNotRecolorBackground() throws {
        let image = try XCTUnwrap(loadReferenceCursorWindowImage())
        let softened = try XCTUnwrap(SoftwareCursorGlyphStyle.today.makeReferenceArtwork(from: image))
        let mask = try render(style: .upstream, reference: softened)
        let tinted = try render(style: .today, reference: softened)
        let composite = try render(style: .today, reference: softened, background: .red)
        var opaquePixels = 0
        for offset in stride(from: 0, to: tinted.count, by: 4) {
            XCTAssertEqual(Int(tinted[offset + 3]), Int(mask[offset + 3]), accuracy: 1)
            if tinted[offset + 3] > 250 {
                opaquePixels += 1
                let alpha = Double(tinted[offset + 3])
                XCTAssertEqual(Double(tinted[offset]) / alpha, 0.01, accuracy: 0.01)
                XCTAssertEqual(Double(tinted[offset + 1]) / alpha, 0.66, accuracy: 0.01)
                XCTAssertEqual(Double(tinted[offset + 2]) / alpha, 0.96, accuracy: 0.01)
            }
        }
        XCTAssertGreaterThan(opaquePixels, 0)
        XCTAssertEqual(Array(composite.prefix(4)), [255, 0, 0, 255])
        XCTAssertEqual(try imageBytes(image), try imageBytes(XCTUnwrap(loadReferenceCursorWindowImage())))
    }

    func testProceduralFallbackSoftensFogEvenAtMinimumOpacity() throws {
        for fogOpacity: CGFloat in [0, 0.12, 1] {
            let state = SoftwareCursorGlyphRenderState(
                rotation: 0, cursorBodyOffset: .zero, fogOffset: .zero,
                fogOpacity: fogOpacity, fogScale: 1, clickProgress: 0
            )
            let upstream = try render(style: .upstream, reference: nil, state: state)
            let today = try render(style: .today, reference: nil, state: state)
            // 采样点位于轮廓与阴影之外，只包含径向光晕。
            let offset = (63 * 126 + 83) * 4
            XCTAssertGreaterThan(upstream[offset + 3], 0)
            XCTAssertEqual(Double(today[offset + 3]), Double(upstream[offset + 3]) * 0.35, accuracy: 1)
            XCTAssertEqual(today[3], 0)
        }
    }

    func testPublicRendererUsesCurrentEnvironmentTheme() throws {
        let style = SoftwareCursorGlyphStyle.resolve()
        let image = try XCTUnwrap(loadReferenceCursorWindowImage())
        let reference = try XCTUnwrap(style.makeReferenceArtwork(from: image))
        let expected = try render(style: style, reference: reference)
        let bitmap = try makeBitmap(width: 126, height: 126)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        SoftwareCursorGlyphRenderer.draw(in: bounds, context: bitmap, state: neutralState)
        XCTAssertEqual(try bytes(bitmap), expected)
    }

    func testTintKeepsMovingReferenceGeometryAndRestoresGraphicsState() throws {
        let image = try XCTUnwrap(loadReferenceCursorWindowImage())
        let softened = try XCTUnwrap(SoftwareCursorGlyphStyle.today.makeReferenceArtwork(from: image))
        let state = SoftwareCursorGlyphRenderState(
            rotation: 0.7, cursorBodyOffset: CGVector(dx: 3, dy: -2),
            fogOffset: CGVector(dx: -4, dy: 2), fogOpacity: 0.2, fogScale: 1.2, clickProgress: 0.8
        )
        let mask = try render(style: .upstream, reference: softened, state: state)
        let tinted = try render(style: .today, reference: softened, state: state)
        for offset in stride(from: 3, to: mask.count, by: 4) {
            XCTAssertEqual(Int(mask[offset]), Int(tinted[offset]), accuracy: 1)
        }
        let bitmap = try makeBitmap(width: 126, height: 126)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        bitmap.setFillColor(NSColor.red.cgColor)
        let transform = bitmap.ctm
        SoftwareCursorGlyphRenderer.draw(
            in: bounds, context: bitmap, state: state, style: .today, referenceArtwork: softened
        )
        XCTAssertEqual(bitmap.ctm, transform)
        bitmap.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        // 位图首行对应画布顶边；左下角位于最后一行。
        let offset = (bitmap.height - 1) * bitmap.bytesPerRow
        XCTAssertEqual(try Array(bytes(bitmap)[offset ..< offset + 4]), [255, 0, 0, 255])
    }

    private func render(
        style: SoftwareCursorGlyphStyle,
        reference: NSImage?,
        state: SoftwareCursorGlyphRenderState? = nil,
        background: NSColor? = nil
    ) throws -> [UInt8] {
        let bitmap = try makeBitmap(width: 126, height: 126)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        if let background {
            bitmap.setFillColor(background.cgColor)
            bitmap.fill(bounds)
        }
        SoftwareCursorGlyphRenderer.draw(
            in: bounds, context: bitmap, state: state ?? neutralState,
            style: style, referenceArtwork: reference
        )
        return try bytes(bitmap)
    }

    private func makeBitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
    }

    private func bytes(_ bitmap: CGContext) throws -> [UInt8] {
        let data = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: bitmap.bytesPerRow * bitmap.height))
    }

    private func imageBytes(_ image: NSImage) throws -> [UInt8] {
        let source = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = try makeBitmap(width: source.width, height: source.height)
        bitmap.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return try bytes(bitmap)
    }
}
