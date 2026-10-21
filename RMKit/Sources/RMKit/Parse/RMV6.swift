import Foundation

/// The v6 scene format: a sequence of typed blocks building a CRDT scene tree.
/// Ported from rmapi-js `rm6.js` (MIT), which follows rmscene (MIT).
/// Only the blocks that carry ink are read; text, glyphs, authors and page
/// info are skipped here.
enum RMV6 {
    static func parse(_ data: Data) throws -> RMPage {
        let reader = ByteReader(data, offset: rmHeaderLength)
        var scene = SceneBuilder()
        var unreadable = 0
        while !reader.atEnd {
            if reader.remaining < 8 {
                // a trailing partial block header: real bytes, but not a whole block
                unreadable += 1
                break
            }
            let length = Int(try reader.u32())
            _ = try reader.u8() // reserved
            _ = try reader.u8() // min version
            let version = try reader.u8()
            let blockType = try reader.u8()
            let start = reader.offset
            guard length <= reader.remaining else {
                unreadable += 1
                break
            }
            let end = start + length
            do {
                try reader.bounded(to: end) {
                    try scene.read(blockType: blockType, version: version, from: reader)
                }
            } catch {
                unreadable += 1
            }
            reader.seek(end)
        }
        return scene.page(unreadableBlocks: unreadable)
    }
}

private struct SceneBuilder {
    enum Value {
        case group(CrdtID)
        case line(RawStroke)
    }

    struct Child {
        let itemID, left, right: CrdtID
        let value: Value
    }

    struct Node {
        var visible: Bool?
        var children: [Child] = []
    }

    var nodes: [CrdtID: Node] = [CrdtID.root: Node()]
    var paperSize: PaperSize?

    mutating func read(blockType: UInt8, version: UInt8, from r: ByteReader) throws {
        switch blockType {
        case 0x02: // tree node: a layer's label and visibility
            let node = try r.id(1)
            _ = try r.lww(2) { try r.string(2) }
            let visible = try r.lww(3) { try r.bool(2) }
            nodes[node, default: Node()].visible = visible
        case 0x04: // group item: a layer placed in its parent
            if let found = try Self.item(r, type: 0x02, { .group(try r.id(2)) }) {
                nodes[found.parent, default: Node()].children.append(found.child)
            }
        case 0x05: // line item: a stroke
            if let found = try Self.item(r, type: 0x03, { .line(try Self.line(r, version: version)) }) {
                nodes[found.parent, default: Node()].children.append(found.child)
            }
        case 0x0d: // scene info
            _ = try r.lww(1) { try r.id(2) }
            if r.hasTag(2, .length4) { _ = try r.lww(2) { try r.bool(2) } }
            if r.hasTag(3, .length4) { _ = try r.lww(3) { try r.bool(2) } }
            if r.hasTag(5, .length4) {
                paperSize = try r.subblock(5) {
                    let width = Int(try r.u32())
                    return PaperSize(width: width, height: Int(try r.u32()))
                }
            }
        default:
            break
        }
    }

    private static func item(
        _ r: ByteReader,
        type itemType: UInt8,
        _ value: () throws -> Value
    ) throws -> (parent: CrdtID, child: Child)? {
        let parent = try r.id(1)
        let itemID = try r.id(2)
        let left = try r.id(3)
        let right = try r.id(4)
        _ = try r.int(5) // deleted length
        guard r.hasTag(6, .length4) else { return nil } // a deleted item has no value
        let found: Value = try r.subblock(6, allowTrailing: true) {
            let foundType = try r.u8()
            guard foundType == itemType else {
                throw RMParseError.unexpectedItemType(found: foundType, wanted: itemType)
            }
            return try value()
        }
        return (parent, Child(itemID: itemID, left: left, right: right, value: found))
    }

    private static func line(_ r: ByteReader, version: UInt8) throws -> RawStroke {
        let penCode = Int(try r.int(1))
        guard let pen = Pen(code: penCode) else { throw RMParseError.unknownPen(penCode) }
        let colorCode = Int(try r.int(2))
        guard let color = InkColor(code: colorCode) else { throw RMParseError.unknownColor(colorCode) }
        let thicknessScale = try r.double(3)
        _ = try r.float(4) // starting length
        let points: [RawPoint] = try r.subblock(5) {
            let size = version == 1 ? 24 : 14
            let count = r.remaining / size
            var points: [RawPoint] = []
            points.reserveCapacity(count)
            for _ in 0..<count {
                let x = try Double(r.f32())
                let y = try Double(r.f32())
                if version == 1 {
                    let speed = try Double(r.f32()) * 4
                    let direction = try Double(r.f32()) * 255 / (2 * Double.pi)
                    let width = try Double(r.f32()) * 4
                    let pressure = try Double(r.f32()) * 255
                    points.append(RawPoint(x: x, y: y, speed: speed, direction: direction, width: width, pressure: pressure))
                } else {
                    let speed = try Double(r.u16())
                    let width = try Double(r.u16())
                    let direction = try Double(r.u8())
                    let pressure = try Double(r.u8())
                    points.append(RawPoint(x: x, y: y, speed: speed, direction: direction, width: width, pressure: pressure))
                }
            }
            return points
        }
        if r.hasTag(6, .id) { _ = try r.id(6) } // timestamp
        if r.hasTag(7, .id) { _ = try r.id(7) } // move id
        let rgba = r.hasTag(8, .byte4) ? try r.int(8) : nil
        return RawStroke(
            pen: pen, color: color, colorRgba: rgba, thicknessScale: thicknessScale,
            points: points, id: nil, hidden: false)
    }

    /// Groups past this nesting are not walked; real pages nest 1-2 levels, so
    /// this is only ever reached by a hostile or corrupted file.
    private static let maxWalkDepth = 64

    /// Flatten the tree back to front. The root holds layers; a hidden layer
    /// hides everything under it. The root's own `visible`, if a file sets
    /// one, is not honoured, matching rm2agent: only layers below the root
    /// can be hidden.
    func page(unreadableBlocks: Int) -> RMPage {
        var strokes: [RawStroke] = []
        var visited: Set<CrdtID> = []
        var skippedForDepth = 0
        func walk(_ id: CrdtID, hidden: Bool, groupsOnly: Bool, depth: Int) {
            guard depth <= Self.maxWalkDepth else {
                skippedForDepth += 1
                return
            }
            guard let node = nodes[id], visited.insert(id).inserted else { return }
            let hidden = id == .root ? hidden : (hidden || node.visible == false)
            let ordered = Toposort.order(node.children, id: \.itemID, left: \.left, right: \.right)
            for child in ordered {
                switch child.value {
                case .group(let group):
                    walk(group, hidden: hidden, groupsOnly: false, depth: depth + 1)
                case .line(var stroke) where !groupsOnly:
                    stroke.id = child.itemID
                    stroke.hidden = hidden
                    strokes.append(stroke)
                case .line:
                    break
                }
            }
        }
        walk(.root, hidden: false, groupsOnly: true, depth: 0)
        return RMPage(
            version: 6, strokes: strokes, paperSize: paperSize,
            unreadableBlocks: unreadableBlocks + skippedForDepth)
    }
}
