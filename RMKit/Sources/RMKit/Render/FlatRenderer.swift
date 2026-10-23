#if canImport(CoreGraphics)
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Flat ink with Core Graphics: the same stroke runs and paint as the SVG
/// port, unrounded, plus typed text and text highlights, which only this
/// renderer draws (the SVG leaves them out to stay byte-identical with rm2agent). A translucent
/// stroke is drawn in one transparency layer, so its overlapping runs don't
/// darken each other.
public enum FlatRenderer {
    public enum RenderError: Error {
        case badScale(Double)
        case tooLarge(width: Double, height: Double)
        /// A Core Graphics resource Core Graphics itself refused to hand back.
        case unavailable(String)
    }

    /// Draw into a context whose user space is page coordinates, y down.
    /// Restores the context's state before returning, even on a thrown error.
    public static func draw(_ page: NormalizedPage, in context: CGContext) throws {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        drawText(page.text, in: context)
        // highlights next, under the ink; one layer each so overlapping rectangles don't darken
        for highlight in page.highlights where !highlight.rects.isEmpty {
            context.saveGState()
            context.setAlpha(highlight.style.opacity)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setFillColor(color(highlight.style.color))
            context.fill(highlight.rects)
            context.endTransparencyLayer()
            context.restoreGState()
        }
        for stroke in page.strokes {
            let runs = try SVG.runs(stroke.points)
            guard !runs.isEmpty else { continue }
            let opacity = stroke.style.opacity
            if opacity < 1 {
                context.saveGState()
                context.setAlpha(opacity)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            context.setStrokeColor(color(stroke.style.color))
            for run in runs {
                context.beginPath()
                context.move(to: CGPoint(x: run.points[0].x, y: run.points[0].y))
                // a one-point run still draws: a zero-length segment with a round cap is a dot
                for point in run.points.count == 1 ? run.points[...] : run.points.dropFirst() {
                    context.addLine(to: CGPoint(x: point.x, y: point.y))
                }
                context.setLineWidth(run.width)
                context.strokePath()
            }
            if opacity < 1 {
                context.endTransparencyLayer()
                context.restoreGState()
            }
        }
    }

    /// Typed text set in the system sans, sized by eye against the tablet; list
    /// markers as characters, the way rmc's text exporters show them.
    static func typeset(_ lines: [TextLine]) -> [(line: CTLine, at: CGPoint)] {
        var fonts: [ParagraphStyle: CTFont] = [:]
        return lines.compactMap { line in
            let (marker, size, font): (String, Double, CTFontUIFontType) = switch line.style {
            case .heading: ("", 46, .emphasizedSystem)
            case .bold: ("", 29, .emphasizedSystem)
            case .bullet: ("•  ", 29, .system)
            case .bullet2: ("      ◦  ", 29, .system)
            case .checkbox: ("☐  ", 29, .system)
            case .checkboxChecked: ("☑  ", 29, .system)
            case .basic, .plain: ("", 29, .system)
            }
            if fonts[line.style] == nil { fonts[line.style] = CTFontCreateUIFontForLanguage(font, size, nil) }
            guard let face = fonts[line.style] else { return nil }
            let string = NSAttributedString(string: marker + line.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): face,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
            return (CTLineCreateWithAttributedString(string), CGPoint(x: line.x, y: line.y))
        }
    }

    static func drawText(_ lines: [TextLine], in context: CGContext) {
        guard !lines.isEmpty else { return }
        context.saveGState()
        // the text matrix (and so the text position) is not part of the graphics state
        let textMatrix = context.textMatrix
        defer {
            context.textMatrix = textMatrix
            context.restoreGState()
        }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1) // the context is y down
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for (line, at) in typeset(lines) {
            context.textPosition = at
            CTLineDraw(line, context)
        }
    }

    /// The SVG's box grown down to cover the typed text too, which the SVG leaves
    /// out: a long note runs past the page bottom like ink can. Only down: a
    /// paragraph is one unwrapped line, and widening for it would shrink the page.
    // ponytail: no word wrap, so a long paragraph runs off the right edge; wrap at RootText.width to fix
    static func paintBox(_ page: NormalizedPage) throws -> Box {
        var box = try SVG.paintBox(page)
        for (line, at) in typeset(page.text) {
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, nil, &descent, nil)
            box.height = max(box.y + box.height, at.y + descent) - box.y
        }
        return box
    }

    /// The page on white with its template under the ink, covering the same box
    /// as the SVG, grown for typed text past it.
    public static func image(_ page: NormalizedPage, scale: Double, template: PageTemplate = .blank) throws -> CGImage {
        guard scale.isFinite, scale > 0 else { throw RenderError.badScale(scale) }
        let box = try paintBox(page)
        let w = (box.width * scale).rounded(.up), h = (box.height * scale).rounded(.up)
        // ponytail: refuse rather than tile; 16k a side is ~1 GB of RGBA, tile when the app needs deep zoom
        guard w >= 1, h >= 1, w <= 16_384, h <= 16_384 else { throw RenderError.tooLarge(width: w, height: h) }
        let width = Int(w), height = Int(h)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw RenderError.unavailable("sRGB color space")
        }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RenderError.unavailable("bitmap context \(width)x\(height)") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -box.x, y: -box.y)
        // a page scrolled past its bottom on the tablet keeps its template all the way down
        template.draw(in: context, page: page.geometry, bottom: box.y + box.height)
        try draw(page, in: context)
        guard let image = context.makeImage() else { throw RenderError.unavailable("image from bitmap context") }
        return image
    }

    public static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.unavailable("PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.unavailable("PNG encoding") }
        return data as Data
    }

    static func color(_ hex: String) -> CGColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return CGColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1)
    }
}
#endif
