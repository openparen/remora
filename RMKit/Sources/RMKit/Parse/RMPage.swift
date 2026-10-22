import Foundation

/// A CRDT identifier: the author's slot and that author's running counter.
public struct CrdtID: Hashable, Sendable {
    public let author: UInt8
    public let counter: UInt64

    public init(author: UInt8, counter: UInt64) {
        self.author = author
        self.counter = counter
    }

    static let root = CrdtID(author: 0, counter: 1)
    static let end = CrdtID(author: 0, counter: 0)
}

/// One sample as the file stores it. v6 values are on v6's integer scales
/// (width in quarter pixels, pressure 0...255); v3/v5 values are as stored.
public struct RawPoint: Sendable, Equatable {
    public var x, y, speed, direction, width, pressure: Double
}

public struct RawStroke: Sendable {
    public var pen: Pen
    public var color: InkColor
    public var colorRgba: UInt32?
    public var thicknessScale: Double
    public var points: [RawPoint]
    /// The scene item's id; v3/v5 strokes have none.
    public var id: CrdtID?
    /// On a layer the user hid.
    public var hidden: Bool
}

public struct PaperSize: Sendable, Equatable {
    public var width: Int
    public var height: Int
}

/// A parsed `.rm` page, every version flattened to strokes back to front.
public struct RMPage: Sendable {
    public var version: Int
    public var strokes: [RawStroke]
    /// Only v6 pages made on a device that knew its screen carry one.
    public var paperSize: PaperSize?
    /// Blocks of a kind we read that failed to parse. Non-zero means content
    /// may be missing: ink or highlights.
    public var unreadableBlocks: Int
    /// Text highlights (v6 glyph items): rectangles over PDF or typed text, back to front.
    public var highlights: [RawHighlight] = []
}

/// A highlight over text, as the file stores it: rectangles in the same
/// coordinates as stroke points.
public struct RawHighlight: Sendable {
    public struct Rect: Sendable, Equatable {
        public var x, y, width, height: Double
    }
    public var color: InkColor
    public var colorRgba: UInt32?
    public var text: String
    public var rects: [Rect]
    public var hidden: Bool
}

public enum RMParseError: Error, Equatable {
    case notAnRMFile
    case unsupportedVersion(String)
    case truncated
    case unexpectedTag(raw: UInt64, wanted: UInt64)
    case subblockNotConsumed(index: UInt64)
    case unknownPen(Int)
    case unknownColor(Int)
    case unexpectedItemType(found: UInt8, wanted: UInt8)
}

let rmHeaderLength = 43
