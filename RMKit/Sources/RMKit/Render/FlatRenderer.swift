import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Flat ink with Core Graphics: the same runs and paint as the SVG port,
/// unrounded. A translucent stroke is drawn in one transparency layer, so its
/// overlapping runs don't darken each other.
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

    /// The page on white, covering the same box as the SVG.
    public static func image(_ page: NormalizedPage, scale: Double) throws -> CGImage {
        guard scale.isFinite, scale > 0 else { throw RenderError.badScale(scale) }
        let box = try SVG.paintBox(page)
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
