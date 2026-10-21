import CoreGraphics
import Foundation
import Testing
@testable import RMKit

@Suite struct TemplatesTests {
    let rm2 = PageGeometry(portrait: nil, orientation: .portrait)
    let paperPro = PageGeometry(portrait: PaperSize(width: 1620, height: 2160), orientation: .portrait)

    @Test func namesMapToTheirFamilies() {
        #expect(PageTemplate(name: nil, page: rm2) == .blank)
        #expect(PageTemplate(name: "Blank", page: rm2) == .blank)
        #expect(PageTemplate(name: "P Lines medium", page: rm2) == .lines(spacing: 78.7, top: 177.8))
        #expect(PageTemplate(name: "LS Lines small", page: rm2) == .lines(spacing: 52, top: 0))
        // the grid sits through the page's "paper origin", W/2 - H/2: -234 on rm2, -270 on Paper Pro
        #expect(PageTemplate(name: "P Grid medium", page: rm2) == .grid(spacing: 78.3, x: -234))
        #expect(PageTemplate(name: "P Grid medium", page: paperPro) == .grid(spacing: 78.3, x: -270))
        #expect(PageTemplate(name: "P Dots large", page: rm2) == .dots(spacing: 78, x: -237))
        #expect(PageTemplate(name: "Isometric", page: rm2) == nil)
    }

    @Test func latticesStartOnThePage() {
        #expect(abs(PageTemplate.firstOnPage(-234, 78.3) - (-234 + 3 * 78.3)) < 1e-9)
        #expect(PageTemplate.firstOnPage(10, 52) == 10)
        let rows = PageTemplate.lattice(from: 177.8, every: 78.7, upTo: 400)
        #expect(rows.count == 3) // 177.8, 256.5, 335.2
        #expect(abs(rows[1] - 256.5) < 1e-9)
    }

    /// The darkness (255 minus red) at a pixel, rows from the top.
    func ink(_ image: CGImage, _ x: Int, _ y: Int) -> Int {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return 255 - Int(pixels[(y * image.width + x) * 4])
    }

    @Test func linesAreDrawnUnderTheInk() throws {
        let blank = NormalizedPage(strokes: [], drops: PageDrops(), geometry: rm2)
        let image = try FlatRenderer.image(blank, scale: 1, template: .lines(spacing: 78.7, top: 177.8))
        #expect(ink(image, 700, 178) > 60) // the first line, antialiased across rows 177-178
        #expect(ink(image, 700, 100) == 0) // the header area above it stays white
        #expect(ink(image, 700, 217) == 0) // halfway to the next line
    }
}
