import Foundation

/// One sample along a stroke, in page coordinates.
public struct StrokePoint: Sendable, Equatable {
    public var x, y: Double
    /// Already includes pressure for the pens that respond to it: never scale it again.
    public var width: Double
    /// 0...1
    public var pressure: Double
}

public struct NormalizedStroke: Sendable {
    public var points: [StrokePoint]
    public var style: StrokeStyle
    public var id: CrdtID?
}

/// Everything on the page that is not in the stroke list, counted.
public struct PageDrops: Sendable, Equatable {
    public var eraserStrokes = 0
    public var hiddenStrokes = 0
    public var emptyStrokes = 0
    public var nonFinitePoints = 0
    public var clampedWidths = 0
    public var clampedPressures = 0
    public var unreadableBlocks = 0

    /// Erasers and hidden layers are the page as the user left it; the rest is loss.
    public var isLossy: Bool {
        emptyStrokes + nonFinitePoints + clampedWidths + clampedPressures + unreadableBlocks > 0
    }
}

public struct NormalizedPage: Sendable {
    public var strokes: [NormalizedStroke]
    public var drops: PageDrops
    public var geometry: PageGeometry
}

/// The narrowest a stroke is drawn; defensive, real widths start at 1.5.
private let minWidth = 0.5

/// Every `.rm` version in, one back-to-front stroke list in page coordinates
/// out. Ported from rm2agent `strokes.ts`. Orientation is a document-level
/// fact from `.content`; no page carries it.
public func normalize(_ page: RMPage, orientation: Orientation) -> NormalizedPage {
    let geometry = PageGeometry(portrait: page.paperSize, orientation: orientation)
    // v6 stores widths in quarter pixels and pressure as a byte
    let widthDivisor = page.version == 6 ? 4.0 : 1.0
    let pressureDivisor = page.version == 6 ? 255.0 : 1.0
    var drops = PageDrops(unreadableBlocks: page.unreadableBlocks)
    var strokes: [NormalizedStroke] = []

    for raw in page.strokes {
        if raw.hidden {
            drops.hiddenStrokes += 1
            continue
        }
        let style = Palette.style(pen: raw.pen, color: raw.color, rgba: raw.colorRgba)
        if style.erase {
            drops.eraserStrokes += 1
            continue
        }
        var points: [StrokePoint] = []
        points.reserveCapacity(raw.points.count)
        for point in raw.points {
            let (x, y) = geometry.toPage(x: point.x, y: point.y, version: page.version)
            guard x.isFinite, y.isFinite else {
                drops.nonFinitePoints += 1
                continue
            }
            var width = point.width / widthDivisor
            if !width.isFinite || width < minWidth {
                drops.clampedWidths += 1
                width = minWidth
            }
            var pressure = point.pressure / pressureDivisor
            if !pressure.isFinite {
                drops.clampedPressures += 1
                pressure = 0
            }
            points.append(StrokePoint(x: x, y: y, width: width, pressure: pressure))
        }
        if points.isEmpty {
            drops.emptyStrokes += 1
            continue
        }
        strokes.append(NormalizedStroke(points: points, style: style, id: raw.id))
    }
    return NormalizedPage(strokes: strokes, drops: drops, geometry: geometry)
}
