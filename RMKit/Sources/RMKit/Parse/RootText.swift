import Foundation

/// A typed paragraph's style, as the v6 root text stores it. Values follow rmscene.
public enum ParagraphStyle: Int, Sendable {
    case basic = 0, plain, heading, bold, bullet, bullet2, checkbox, checkboxChecked
}

/// A v6 page's typed text (the root text block), split into paragraphs.
/// Ported from rmscene `TextDocument.from_scene_item`.
public struct RootText: Sendable, Equatable {
    public struct Paragraph: Sendable, Equatable {
        public var style: ParagraphStyle
        public var text: String
        /// The newline that opens this paragraph, or `.end` for the first one.
        var startID: CrdtID
        /// One id per character, deleted characters included: any can be an anchor.
        var charIDs: [CrdtID]
    }

    public var paragraphs: [Paragraph]
    /// The text box's left edge (centre-relative, like stroke x), its top, and its width.
    public var x, y, width: Double

    /// Anchors that pin a group to the text's top or bottom rather than a character.
    static let topAnchor = CrdtID(author: 0, counter: 0xffff_ffff_fffe)
    static let bottomAnchor = CrdtID(author: 0, counter: 0xffff_ffff_ffff)

    // ponytail: rmc's fixed per-style line heights, no word wrap and no font
    // metrics, so a paragraph that wraps on the tablet pushes everything below
    // it down there but not here. Lay out with real metrics if that shows up.
    static func lineHeight(_ style: ParagraphStyle) -> Double {
        switch style {
        case .heading: 150
        case .bullet, .bullet2, .checkbox, .checkboxChecked: 35
        case .basic, .plain, .bold: 70
        }
    }

    /// rmc's `TEXT_TOP_Y`: where the first paragraph's anchors sit, above `y`.
    static let topOffset = -88.0
    /// Where the tablet puts the top anchor below `y`: a stroke-for-stroke match
    /// of rmscene's `Lines_v2.rm` and its firmware-migrated `Lines_v2_updated.rm`
    /// (rmc's `y + topOffset` would put those strokes 121.6 too high).
    static let topAnchorOffset = 33.59375

    /// Each paragraph's top, rmc's layout: they stack by their style's line height.
    func tops() -> [Double] {
        var top = y + Self.topOffset
        return paragraphs.map { paragraph in
            defer { top += Self.lineHeight(paragraph.style) }
            return top
        }
    }

    /// The y each anchor id stands for, in the file's coordinates.
    func anchors() -> [CrdtID: Double] {
        var result: [CrdtID: Double] = [:]
        var bottom = y + Self.topOffset
        for (paragraph, top) in zip(paragraphs, tops()) {
            result[paragraph.startID] = top
            for id in paragraph.charIDs { result[id] = top }
            bottom = top + Self.lineHeight(paragraph.style)
        }
        result[Self.topAnchor] = y + Self.topAnchorOffset
        result[Self.bottomAnchor] = bottom
        return result
    }

    /// Without typed text rmc pins the special anchors to the page's top and bottom.
    static func anchors(_ text: RootText?, pageHeight: Double) -> [CrdtID: Double] {
        text?.anchors() ?? [topAnchor: 0, bottomAnchor: pageHeight]
    }
}

extension RootText {
    /// One CRDT text item: a run of characters, a format code, or a deleted run.
    struct Item {
        enum Value { case text(String), format, deleted(Int) }
        let id, left, right: CrdtID
        let value: Value
    }

    /// No real page comes near this; it bounds what a hostile deleted length can allocate.
    static let maxChars = 1_000_000

    /// Expand runs to one item per character (ids run on from the run's id),
    /// order them, then split at newlines. Characters are Unicode scalars, as
    /// in rmscene. Inline bold/italic codes are skipped.
    init(items: [Item], styles: [CrdtID: ParagraphStyle], x: Double, y: Double, width: Double) throws {
        struct Char { let id, left, right: CrdtID; let char: Unicode.Scalar?; let format: Bool }
        var chars: [Char] = []
        for item in items {
            let scalars: [Unicode.Scalar?]
            switch item.value {
            case .format:
                chars.append(Char(id: item.id, left: item.left, right: item.right, char: nil, format: true))
                continue
            case .text(let text): scalars = text.unicodeScalars.map { $0 }
            case .deleted(let count):
                guard count <= Self.maxChars else { throw RMParseError.truncated }
                scalars = Array(repeating: nil, count: count)
            }
            guard !scalars.isEmpty else { continue }
            guard chars.count + scalars.count <= Self.maxChars,
                  item.id.counter <= UInt64.max - UInt64(scalars.count) else { throw RMParseError.truncated }
            var left = item.left
            for (i, scalar) in scalars.enumerated() {
                let id = CrdtID(author: item.id.author, counter: item.id.counter + UInt64(i))
                let right = i == scalars.count - 1 ? item.right : CrdtID(author: id.author, counter: id.counter + 1)
                chars.append(Char(id: id, left: left, right: right, char: scalar, format: false))
                left = id
            }
        }
        let ordered = Toposort.order(chars, id: \.id, left: \.left, right: \.right)

        var paragraphs: [Paragraph] = []
        var i = 0
        while i < ordered.count {
            var start = CrdtID.end
            if ordered[i].char == "\n" {
                start = ordered[i].id
                i += 1
            }
            var text = String.UnicodeScalarView()
            var ids: [CrdtID] = []
            while i < ordered.count, ordered[i].char != "\n" {
                if !ordered[i].format {
                    if let char = ordered[i].char { text.append(char) }
                    ids.append(ordered[i].id)
                }
                i += 1
            }
            paragraphs.append(Paragraph(style: styles[start] ?? .plain, text: String(text), startID: start, charIDs: ids))
        }
        self.init(paragraphs: paragraphs, x: x, y: y, width: width)
    }
}
