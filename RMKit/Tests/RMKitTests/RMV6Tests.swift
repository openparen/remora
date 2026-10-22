import Foundation
import Testing
@testable import RMKit

@Suite struct RMV6Tests {
    @Test func readsEveryStrokeOfASample() throws {
        let page = try parseRM(try Fixtures.data("Color_and_tool_v3.14.4", "rm"))
        #expect(page.version == 6)
        #expect(page.unreadableBlocks == 0)
        #expect(page.strokes.count == 25)
        #expect(Set(page.strokes.map(\.pen)) == [.ballpoint, .shader])
        #expect(page.strokes.contains { $0.colorRgba != nil }) // the shader carries its own colour
        #expect(page.strokes.allSatisfy { $0.id != nil && !$0.points.isEmpty })
    }

    @Test func aTextOnlyPageHasNoStrokes() throws {
        let page = try parseRM(try Fixtures.data("Normal_AB", "rm"))
        #expect(page.strokes.isEmpty)
        #expect(page.unreadableBlocks == 0)
    }

    @Test func aTruncatedFileKeepsWhatParsedAndSaysSo() throws {
        let data = try Fixtures.data("Color_and_tool_v3.14.4", "rm")
        let page = try parseRM(data.prefix(data.count - 10))
        #expect(page.unreadableBlocks > 0)
        #expect(page.strokes.count > 0)
    }

    @Test func refusesSomethingElse() {
        #expect(throws: RMParseError.notAnRMFile) { try parseRM(Data("hello".utf8)) }
    }

    // MARK: hostile-file regressions

    /// Little-endian helpers to hand-build minimal v6 byte sequences.
    private func varuintBytes(_ value: UInt64) -> [UInt8] {
        var v = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while v != 0
        return bytes
    }

    private func idBytes(_ tagIndex: UInt64, _ id: CrdtID) -> [UInt8] {
        varuintBytes(tagIndex << 4 | 0xf) + [id.author] + varuintBytes(id.counter)
    }

    private func intBytes(_ tagIndex: UInt64, _ value: UInt32) -> [UInt8] {
        varuintBytes(tagIndex << 4 | 0x4) + withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private func subblockHeaderBytes(_ tagIndex: UInt64, length: Int) -> [UInt8] {
        varuintBytes(tagIndex << 4 | 0xc) + withUnsafeBytes(of: UInt32(length).littleEndian) { Array($0) }
    }

    private func blockBytes(type: UInt8, version: UInt8 = 1, body: [UInt8]) -> [UInt8] {
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { Array($0) } + [0, 0, version, type] + body
    }

    private func v6Header() -> Data {
        Data("reMarkable .lines file, version=6".padding(toLength: 43, withPad: " ", startingAt: 0).utf8)
    }

    /// The trap found while hardening this plan: a tree-node (0x02) label
    /// whose varuint length is `ff ff ff ff ff ff ff ff ff 01` (bit 63 set,
    /// out of `Int64`'s range) must not crash `Int(_:)`.
    @Test func hostileVaruintLengthDoesNotTrap() throws {
        let hostileVaruint: [UInt8] = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01]
        let stringSubblock = subblockHeaderBytes(2, length: hostileVaruint.count) + hostileVaruint
        let lww2Body = idBytes(1, CrdtID(author: 0, counter: 1)) + stringSubblock // timestamp + string
        let lww2 = subblockHeaderBytes(2, length: lww2Body.count) + lww2Body
        let body = idBytes(1, CrdtID(author: 0, counter: 1)) + lww2 // node id + label lww

        var data = v6Header()
        data.append(contentsOf: blockBytes(type: 0x02, body: body))

        let page = try parseRM(data)
        #expect(page.unreadableBlocks >= 1)
    }

    /// A label length that fits `Int` but dwarfs the file used to overflow
    /// the `offset + count` bounds check in `take()`.
    @Test func labelLengthNearIntMaxDoesNotOverflow() throws {
        let nearMaxVaruint = varuintBytes(UInt64(Int.max - 2))
        let stringSubblock = subblockHeaderBytes(2, length: nearMaxVaruint.count) + nearMaxVaruint
        let lww2Body = idBytes(1, CrdtID(author: 0, counter: 1)) + stringSubblock // timestamp + string
        let lww2 = subblockHeaderBytes(2, length: lww2Body.count) + lww2Body
        let body = idBytes(1, CrdtID(author: 0, counter: 1)) + lww2 // node id + label lww

        var data = v6Header()
        data.append(contentsOf: blockBytes(type: 0x02, body: body))

        let page = try parseRM(data)
        #expect(page.unreadableBlocks >= 1)
    }

    /// A chain of ~1000 nested group items must not blow the stack when the
    /// tree is flattened back to front.
    @Test func deeplyNestedGroupsDoNotCrashAndAreCounted() throws {
        func groupItemBody(parent: CrdtID, itemID: CrdtID, group: CrdtID) -> [UInt8] {
            let innerValue: [UInt8] = [0x02] + idBytes(2, group)
            return idBytes(1, parent) + idBytes(2, itemID) + idBytes(3, .end) + idBytes(4, .end)
                + intBytes(5, 0) + subblockHeaderBytes(6, length: innerValue.count) + innerValue
        }

        var data = v6Header()
        var parent = CrdtID.root
        for i in 1...1000 {
            let group = CrdtID(author: 1, counter: UInt64(i))
            let itemID = CrdtID(author: 2, counter: UInt64(i))
            data.append(contentsOf: blockBytes(type: 0x04, body: groupItemBody(parent: parent, itemID: itemID, group: group)))
            parent = group
        }

        let page = try parseRM(data)
        #expect(page.unreadableBlocks > 0)
    }
}

@Suite struct HighlightParseTests {
    @Test func readsTextHighlightsInStrokeCoordinates() throws {
        let page = try parseRM(try Fixtures.data("Wikipedia_highlighted_p1", "rm"))
        #expect(page.unreadableBlocks == 0)
        #expect(page.highlights.count == 4)
        #expect(page.highlights[0].text.hasPrefix("The reMarkable uses electronic"))
        #expect(page.highlights[0].color == .yellow)
        let ink = normalize(page, orientation: .portrait)
        // x is centre-relative like stroke points, so normalize shifts it by half the page
        #expect(abs(ink.highlights[0].rects[0].minX - (page.highlights[0].rects[0].x + ink.geometry.width / 2)) < 1e-9)
        #expect(ink.highlights[0].style.opacity == 0.35)
    }
}
