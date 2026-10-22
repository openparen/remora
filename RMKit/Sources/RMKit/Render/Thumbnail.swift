import CoreGraphics
import Foundation

/// A document's first page, small, for the library's grid.
public enum Thumbnail {
    /// The first page drawn `width` pixels wide, as the document shows it: a
    /// notebook page on its template, a PDF or EPUB page with its ink on top.
    /// nil for a document with no pages or an unreadable PDF.
    // ponytail: a PDF's thumbnail downloads the whole PDF; the cache keeps it, but a huge book costs its size once
    public static func render(_ document: Document, width: Double, blobs: BlobStore) async throws -> CGImage? {
        guard let first = document.pages.first else { return nil }
        if let file = document.pdfFile, let number = first.sourcePage {
            let data = try await blobs.data(hash: file.hash, name: file.id)
            guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider),
                  let page = pdf.page(at: number) else { return nil }
            return pdfPage(page, ink: try await document.ink(first, blobs: blobs), width: width)
        }
        // a notebook page, or a page inserted into a PDF on the tablet
        let pageWidth = document.content.orientation == .landscape ? 1872.0 : 1404.0
        return try await document.render(first, scale: width / pageWidth, blobs: blobs).image
    }

    /// A PDF page as shown (crop box, /Rotate applied) `width` pixels wide, its ink on top.
    static func pdfPage(_ page: CGPDFPage, ink: NormalizedPage?, width: Double) -> CGImage? {
        let crop = page.getBoxRect(.cropBox).size
        let displayed = page.rotationAngle % 180 == 0 ? crop : CGSize(width: crop.height, height: crop.width)
        guard displayed.width > 0, displayed.height > 0, width > 0 else { return nil }
        let scale = width / displayed.width
        let w = Int(width.rounded(.up)), h = Int((displayed.height * scale).rounded(.up))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        // the drawing transform applies the page's /Rotate and puts its crop box at the origin
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: displayed), rotate: 0, preserveAspectRatio: true))
        context.clip(to: page.getBoxRect(.cropBox))
        context.drawPDFPage(page)
        context.restoreGState()
        if let ink {
            // ink runs top-left, y down, on the page as shown
            context.translateBy(x: 0, y: displayed.height * scale) // the page's top, not the rounded-up bitmap's
            context.scaleBy(x: scale, y: -scale)
            context.concatenate(PDFPlacement.transform(for: ink, displayed: displayed))
            try? FlatRenderer.draw(ink, in: context)
        }
        return context.makeImage()
    }
}
