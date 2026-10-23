#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import RMKit

@Suite struct ThumbnailTests {
    /// A one-page PDF of `size` points with a black 50 pt square whose top-left
    /// corner is at `corner` (top-left origin; nil for none) and a black band
    /// `band` points tall across its top, turned by `rotation`, cropped to `crop`.
    func pdf(_ size: CGSize, square corner: CGPoint? = .zero, band: CGFloat = 0, rotation: Int = 0, crop: CGRect? = nil) throws -> CGPDFPage {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let context = try #require(CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        if let corner { context.fill(CGRect(x: corner.x, y: size.height - corner.y - 50, width: 50, height: 50)) } // PDF space is y up
        if band > 0 { context.fill(CGRect(x: 0, y: size.height - band, width: size.width, height: band)) }
        context.endPDFPage()
        context.closePDF()
        let document = try #require(PDFDocument(data: data as Data))
        let page = try #require(document.page(at: 0))
        page.rotation = rotation
        if let crop { page.setBounds(crop, for: .cropBox) }
        let saved = try #require(document.dataRepresentation())
        return try #require(CGPDFDocument(CGDataProvider(data: saved as CFData)!)?.page(at: 1))
    }

    func gray(_ image: CGImage, x: Int, y: Int) -> Int {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        // bitmap rows run top down in memory
        return Int(pixels[(y * image.width + x) * 4])
    }

    @Test func anEPUBTheTabletHasNotRenderedHasNoThumbnail() async throws {
        let json = #"{"fileType":"epub","originalPageCount":1,"pageCount":1,"pages":["p1"],"redirectionPageMap":[0]}"#
        let content = try JSONDecoder().decode(DocumentContent.self, from: Data(json.utf8))
        let document = Document(id: "d", files: [], content: content, pages: PageMap.pages(content: content, rmPageIDs: []))
        let store = BlobStore(cache: BlobCache(directory: temporaryDirectory())) { _, _ in throw CloudError.offline }
        #expect(try await Thumbnail.render(document, width: 150, blobs: store) == nil)
    }

    @Test func aPDFPageIsDrawnAtTheWidthAskedUpright() throws {
        let image = try #require(Thumbnail.pdfPage(try pdf(CGSize(width: 600, height: 800)), ink: nil, width: 150))
        #expect(image.width == 150 && image.height == 200)
        #expect(gray(image, x: 3, y: 3) < 50)       // the square, top left
        #expect(gray(image, x: 140, y: 190) > 200)  // white elsewhere
    }

    @Test(arguments: [(0, 3, 3), (90, 157, 3), (180, 117, 157), (270, 3, 117)])
    func aTurnedPageIsShownTurned(rotation: Int, x: Int, y: Int) throws {
        // the square starts top left; /Rotate turns the page clockwise
        let image = try #require(Thumbnail.pdfPage(try pdf(CGSize(width: 600, height: 800), rotation: rotation), ink: nil, width: rotation % 180 == 0 ? 120 : 160))
        #expect(image.width == (rotation % 180 == 0 ? 120 : 160))
        #expect(gray(image, x: x, y: y) < 50)
    }

    @Test func onlyTheCropBoxIsShown() throws {
        // a 300×400 crop box 100 pt in and 120 pt down (PDF y up: origin y = 800 − 120 − 400), the square at its corner
        let page = try pdf(CGSize(width: 600, height: 800), square: CGPoint(x: 100, y: 120), crop: CGRect(x: 100, y: 280, width: 300, height: 400))
        let image = try #require(Thumbnail.pdfPage(page, ink: nil, width: 150))
        #expect(image.width == 150 && image.height == 200)
        #expect(gray(image, x: 3, y: 3) < 50)
        #expect(gray(image, x: 140, y: 190) > 200)
    }

    @Test func nothingAboveTheCropBoxShows() throws {
        // the bitmap is a fractional height rounded up; the extra row must not show what's above the crop box
        let page = try pdf(CGSize(width: 600, height: 800), square: nil, band: 120, crop: CGRect(x: 100, y: 280, width: 300, height: 400))
        let image = try #require(Thumbnail.pdfPage(page, ink: nil, width: 301))
        #expect(gray(image, x: 150, y: 0) > 200)
    }

    @Test func inkLandsWhereThePDFViewPutsIt() throws {
        // a v6 dot at the screen's horizontal centre, 227 px (one inch) down: the shown page's centre, 72 pt down;
        // on a page turned a quarter (800×600 as shown) at half scale, that's (200, 36)
        let dot = StrokePoint(x: 702, y: 227, width: 30, pressure: 1)
        let ink = NormalizedPage(strokes: [NormalizedStroke(points: [dot, dot], style: Palette.style(pen: .fineliner, color: .black, rgba: nil), id: nil)],
                                 drops: PageDrops(), geometry: PageGeometry(portrait: nil, orientation: .portrait), version: 6)
        // ponytail: at a fractional height, ink is placed from the page's top; the sub-pixel difference isn't asserted
        let page = try pdf(CGSize(width: 600, height: 800), square: nil, rotation: 90)
        let image = try #require(Thumbnail.pdfPage(page, ink: ink, width: 400))
        #expect(image.width == 400 && image.height == 300)
        #expect(gray(image, x: 200, y: 36) < 100)
        #expect(gray(image, x: 200, y: 150) > 200)
    }
}
#endif
