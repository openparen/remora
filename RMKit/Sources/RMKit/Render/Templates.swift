import CoreGraphics
import Foundation

/// The built-in page backgrounds Remora draws itself, chosen by template name.
/// The spacing and offsets follow the formulas in reMarkable's own template
/// definitions; the drawing is ours, no reMarkable asset ships.
public enum PageTemplate: Sendable, Equatable {
    case blank
    /// Horizontal lines from `top` down, every `spacing`.
    case lines(spacing: Double, top: Double)
    /// Horizontal lines every `spacing` from the top; vertical lines every `spacing` through `x`.
    case grid(spacing: Double, x: Double)
    /// Dots every `spacing`, rows from the top, columns through `x`.
    case dots(spacing: Double, x: Double)

    /// nil for a template Remora doesn't draw; the viewer shows its name instead.
    /// `page` is the page in its current orientation.
    public init?(name: String?, page: PageGeometry) {
        let w = page.width, h = page.height
        // where reMarkable's formulas put the left edge of the page's square "paper"
        let paperOriginX = w / 2 - h / 2
        switch name ?? "" {
        case "", "Blank", "blank": self = .blank
        // ponytail: P Lines on a page turned landscape spans the full width; reMarkable's spans W/2-H/2 ... +H
        case "P Lines small", "LS Lines small": self = .lines(spacing: 52, top: 0)
        case "P Lines medium", "LS Lines medium": self = .lines(spacing: 78.7, top: 177.8)
        case "P Lines large": self = .lines(spacing: 97, top: 162)
        case "P Grid small": self = .grid(spacing: 52, x: paperOriginX - 25)
        case "P Grid medium": self = .grid(spacing: 78.3, x: paperOriginX)
        case "P Grid large": self = .grid(spacing: 104, x: paperOriginX - 78)
        case "P Dots S": self = .dots(spacing: 42.5, x: paperOriginX - 22 + 1)
        case "P Dots large": self = .dots(spacing: 78, x: (w > h ? 0 : paperOriginX - 1) - 2)
        default: return nil
        }
    }

    /// How dark template marks are drawn, 0 black to 1 white. reMarkable's
    /// definitions say black, but the device shows lines as a mid grey; these
    /// are tuned by eye against the tablet, so adjust here if they look off.
    public static let lineGray = 0.62
    public static let dotGray = 0.45

    /// The first position at or after 0 on a lattice through `origin`.
    static func firstOnPage(_ origin: Double, _ spacing: Double) -> Double {
        let r = origin.truncatingRemainder(dividingBy: spacing)
        return r < 0 ? r + spacing : r
    }

    /// Line y positions, or column x positions, across `length`.
    static func lattice(from start: Double, every spacing: Double, upTo length: Double) -> [Double] {
        Array(stride(from: start, to: length, by: spacing))
    }

    /// Draw on a page-coordinate context, y down, before the ink.
    public func draw(in context: CGContext, page: PageGeometry) {
        let w = page.width, h = page.height
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(CGColor(gray: Self.lineGray, alpha: 1))
        context.setFillColor(CGColor(gray: Self.dotGray, alpha: 1))
        context.setLineWidth(1)
        func hline(_ y: Double) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: w, y: y))
        }
        switch self {
        case .blank:
            return
        case .lines(let spacing, let top):
            for y in Self.lattice(from: top, every: spacing, upTo: h) { hline(y) }
            context.strokePath()
        case .grid(let spacing, let x):
            for y in Self.lattice(from: 0, every: spacing, upTo: h) { hline(y) }
            for x in Self.lattice(from: Self.firstOnPage(x, spacing), every: spacing, upTo: w) {
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: h))
            }
            context.strokePath()
        case .dots(let spacing, let x):
            context.setShouldAntialias(false)
            for y in Self.lattice(from: 0, every: spacing, upTo: h) {
                for x in Self.lattice(from: Self.firstOnPage(x, spacing), every: spacing, upTo: w) {
                    // reMarkable's dot: a 1×1 square stroked 1 wide, so about 2×2 pixels
                    context.fill(CGRect(x: x - 0.5, y: y - 0.5, width: 2, height: 2))
                }
            }
        }
    }
}
