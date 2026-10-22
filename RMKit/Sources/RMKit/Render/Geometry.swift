import Foundation

/// A page's coordinate system, origin top-left, in device pixels.
/// Ported from rm2agent `geometry.ts`.
public struct PageGeometry: Sendable, Equatable {
    /// rm1, rm2 and Paper Pure; the size of any page that declares none.
    public static let defaultScreen = PaperSize(width: 1404, height: 1872)

    public let width: Double
    public let height: Double
    public let orientation: Orientation

    /// `portrait` is the page's native portrait size (a v6 `paperSize`).
    /// A non-positive size is treated as absent, not as a zero- or negative-size page.
    public init(portrait: PaperSize?, orientation: Orientation) {
        let declared = portrait.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        let size = declared ?? Self.defaultScreen
        let short = Double(size.width), long = Double(size.height)
        width = orientation == .landscape ? long : short
        height = orientation == .landscape ? short : long
        self.orientation = orientation
    }

    /// v6 stores x relative to the page's horizontal centre; v3/v5 from the left
    /// edge of the portrait screen, even in a landscape document, which the
    /// tablet shows turned a quarter clockwise.
    func toPage(x: Double, y: Double, version: Int) -> (x: Double, y: Double) {
        if version == 6 { return (x + width / 2, y) }
        return orientation == .landscape ? (width - y, x) : (x, y)
    }
}

public struct Box: Sendable, Equatable {
    public var x, y, width, height: Double
}

struct Bounds {
    var minX, minY, maxX, maxY: Double
}

func bounds<S: Sequence>(of points: S) -> Bounds? where S.Element == (x: Double, y: Double) {
    var result: Bounds?
    for p in points {
        if var b = result {
            b.minX = min(b.minX, p.x); b.minY = min(b.minY, p.y)
            b.maxX = max(b.maxX, p.x); b.maxY = max(b.maxY, p.y)
            result = b
        } else {
            result = Bounds(minX: p.x, minY: p.y, maxX: p.x, maxY: p.y)
        }
    }
    return result
}

/// The page box grown to cover ink dragged off the page, which the move tool allows.
func renderBox(_ page: PageGeometry, ink: Bounds?) -> Box {
    guard let ink else { return Box(x: 0, y: 0, width: page.width, height: page.height) }
    let x = min(0, ink.minX), y = min(0, ink.minY)
    return Box(x: x, y: y, width: max(page.width, ink.maxX) - x, height: max(page.height, ink.maxY) - y)
}
