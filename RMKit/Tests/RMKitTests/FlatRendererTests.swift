import CoreGraphics
import Foundation
import Testing
@testable import RMKit

@Suite struct FlatRendererTests {
    func page(_ strokes: [NormalizedStroke]) -> NormalizedPage {
        NormalizedPage(strokes: strokes, drops: PageDrops(), geometry: PageGeometry(portrait: nil, orientation: .portrait))
    }

    func stroke(_ points: [(Double, Double, Double)], opacity: Double) -> NormalizedStroke {
        NormalizedStroke(
            points: points.map { StrokePoint(x: $0.0, y: $0.1, width: $0.2, pressure: 1) },
            style: StrokeStyle(color: "#000000", opacity: opacity, erase: false, pen: .ballpoint))
    }

    /// The red channel at a pixel, rows counted from the top.
    func red(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels[(y * image.width + x) * 4]
    }

    @Test func drawsInkWhereThePageSaysWithYDown() throws {
        let image = try FlatRenderer.image(page([stroke([(100, 100, 10), (300, 100, 10)], opacity: 1)]), scale: 0.5)
        #expect(image.width == 702)
        #expect(red(image, 100, 50) < 40) // on the line
        #expect(red(image, 100, 800) > 250) // far below it
    }

    @Test func aTranslucentStrokeDoesNotDarkenWhereItOverlapsItself() throws {
        // runs of width 20 then 30 over the same line; only the wide one reaches y = 112
        let ink = page([stroke([(100, 100, 20), (500, 100, 20), (100, 100, 40)], opacity: 0.35)])
        let image = try FlatRenderer.image(ink, scale: 0.5)
        let overlap = Int(red(image, 150, 50)), single = Int(red(image, 150, 56))
        #expect(abs(overlap - single) <= 3)
        #expect(abs(overlap - 166) <= 4) // 255 * (1 - 0.35)
    }

    @Test func paintsAHighlight() throws {
        var ink = page([])
        ink.highlights = [Highlight(
            rects: [CGRect(x: 100, y: 100, width: 200, height: 40)],
            style: StrokeStyle(color: "#000000", opacity: 0.35, erase: false, pen: .highlighter), text: "x")]
        let image = try FlatRenderer.image(ink, scale: 0.5)
        #expect(abs(Int(red(image, 100, 60)) - 166) <= 4) // inside: 255 * (1 - 0.35)
        #expect(red(image, 100, 120) > 250) // below it
    }

    @Test func inkPushedFarOffThePageThrowsTooLarge() throws {
        let ink = page([stroke([(1_000_000, 100, 10)], opacity: 1)])
        do {
            _ = try FlatRenderer.image(ink, scale: 1)
            Issue.record("expected FlatRenderer.RenderError.tooLarge")
        } catch FlatRenderer.RenderError.tooLarge {
            // expected
        }
    }

    @Test func aNonFiniteOrZeroScaleThrowsBadScale() throws {
        let ink = page([stroke([(100, 100, 10), (300, 100, 10)], opacity: 1)])
        for scale in [Double.nan, 0] {
            do {
                _ = try FlatRenderer.image(ink, scale: scale)
                Issue.record("expected FlatRenderer.RenderError.badScale for scale \(scale)")
            } catch FlatRenderer.RenderError.badScale {
                // expected
            }
        }
    }
}
