import CoreGraphics
import Foundation
import Testing
@testable import RMKit

@Suite struct ThumbnailTests {
    /// A one-page PDF, `size` points, with a black square in its top-left corner.
    func pdf(_ size: CGSize) throws -> CGPDFPage {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let context = try #require(CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: size.height - 50, width: 50, height: 50)) // PDF space is y up
        context.endPDFPage()
        context.closePDF()
        return try #require(CGPDFDocument(CGDataProvider(data: data)!)?.page(at: 1))
    }

    func gray(_ image: CGImage, x: Int, y: Int) -> Int {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        // bitmap rows run top down in memory
        return Int(pixels[(y * image.width + x) * 4])
    }

    @Test func aPDFPageIsDrawnAtTheWidthAskedUpright() throws {
        let image = try #require(Thumbnail.pdfPage(try pdf(CGSize(width: 600, height: 800)), ink: nil, width: 150))
        #expect(image.width == 150 && image.height == 200)
        #expect(gray(image, x: 3, y: 3) < 50)       // the square, top left
        #expect(gray(image, x: 140, y: 190) > 200)  // white elsewhere
    }

    @Test func inkLandsWhereThePDFViewPutsIt() throws {
        // a v6 dot at the screen's horizontal centre, 227 px (one inch) down: the page's centre, 72 pt down
        let dot = StrokePoint(x: 702, y: 227, width: 30, pressure: 1)
        let ink = NormalizedPage(strokes: [NormalizedStroke(points: [dot, dot], style: Palette.style(pen: .fineliner, color: .black, rgba: nil), id: nil)],
                                 drops: PageDrops(), geometry: PageGeometry(portrait: nil, orientation: .portrait), version: 6)
        let image = try #require(Thumbnail.pdfPage(try pdf(CGSize(width: 600, height: 800)), ink: ink, width: 600))
        #expect(gray(image, x: 300, y: 72) < 100)
        #expect(gray(image, x: 300, y: 300) > 200)
    }
}
