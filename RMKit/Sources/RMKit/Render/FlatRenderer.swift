import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Flat ink with Core Graphics: the same runs and paint as the SVG port,
/// unrounded. A translucent stroke is drawn in one transparency layer, so its
/// overlapping runs don't darken each other.
public enum FlatRenderer {
    /// Draw into a context whose user space is page coordinates, y down.
    public static func draw(_ page: NormalizedPage, in context: CGContext) throws {
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in page.strokes {
            let runs = try SVG.runs(stroke.points)
            guard !runs.isEmpty else { continue }
            let opacity = stroke.style.opacity
            if opacity < 1 {
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
                context.setAlpha(1)
            }
        }
    }

    /// The page on white, covering the same box as the SVG.
    public static func image(_ page: NormalizedPage, scale: Double) throws -> CGImage {
        let box = try SVG.paintBox(page)
        let width = Int((box.width * scale).rounded(.up)), height = Int((box.height * scale).rounded(.up))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw SVG.Error.nonFinite("bitmap \(width)x\(height)") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -box.x, y: -box.y)
        try draw(page, in: context)
        return context.makeImage()!
    }

    public static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
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
