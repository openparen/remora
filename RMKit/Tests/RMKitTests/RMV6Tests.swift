import CoreGraphics
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

    /// A 0x07 block body: `count` then `items` as the text list, `styles` as
    /// (character, code) pairs, a zero box.
    private func rootTextBody(items: [UInt8], count: UInt64, styles styleList: [(CrdtID, UInt8)] = []) -> [UInt8] {
        let itemList = subblockHeaderBytes(1, length: varuintBytes(count).count + items.count) + varuintBytes(count) + items
        let texts = subblockHeaderBytes(1, length: itemList.count) + itemList
        let entries = styleList.flatMap { char, code in
            [char.author] + varuintBytes(char.counter) + idBytes(1, CrdtID(author: 1, counter: 1))
                + subblockHeaderBytes(2, length: 2) + [17, code]
        }
        let styleBlock = varuintBytes(UInt64(styleList.count)) + entries
        let styleSub = subblockHeaderBytes(1, length: styleBlock.count) + styleBlock
        let styles = subblockHeaderBytes(2, length: styleSub.count) + styleSub
        let box = subblockHeaderBytes(3, length: 16) + [UInt8](repeating: 0, count: 16)
        return idBytes(1, .end) + subblockHeaderBytes(2, length: texts.count + styles.count) + texts + styles
            + box + intBytes(4, 0)
    }

    /// One text item: `text`, or a run of `deleted` characters.
    private func textItem(_ id: CrdtID, left: CrdtID = .end, text: String = "", deleted: UInt32 = 0) -> [UInt8] {
        var fields = idBytes(2, id) + idBytes(3, left) + idBytes(4, .end) + intBytes(5, deleted)
        if !text.isEmpty {
            let string = varuintBytes(UInt64(text.utf8.count)) + [1] + Array(text.utf8)
            fields += subblockHeaderBytes(6, length: string.count) + string
        }
        return subblockHeaderBytes(0, length: fields.count) + fields
    }

    /// Only the last text block is laid out, so earlier ones cost their bytes,
    /// not their characters: neither a run past the cap nor runs at it count.
    @Test func onlyTheLastTextBlockIsExpanded() throws {
        var data = v6Header()
        // 60 blocks: expanding each would take ~10x the limit, not a margin a fast machine could hide
        for i in 0..<60 {
            let run = UInt32(i < 10 ? RootText.maxChars + 1 : RootText.maxChars)
            data.append(contentsOf: blockBytes(type: 0x07, body: rootTextBody(items: textItem(CrdtID(author: 1, counter: 1), deleted: run), count: 1)))
        }
        data.append(contentsOf: blockBytes(type: 0x07, body: rootTextBody(items: textItem(CrdtID(author: 1, counter: 1), text: "A"), count: 1)))
        let start = ContinuousClock.now
        let page = try parseRM(data)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(page.unreadableBlocks == 0)
        #expect(page.text?.paragraphs.map(\.text) == ["A"])
    }

    /// A style code past the known ones reads as plain, as in rmscene.
    @Test func anUnknownParagraphStyleIsPlain() throws {
        var data = v6Header()
        let body = rootTextBody(items: textItem(CrdtID(author: 1, counter: 1), text: "A"), count: 1, styles: [(.end, 9)])
        data.append(contentsOf: blockBytes(type: 0x07, body: body))
        let page = try parseRM(data)
        #expect(page.text?.paragraphs.map(\.style) == [.plain])
    }

    /// A run whose character ids would pass the counter's top is unreadable, not a trap.
    @Test func aTextRunPastTheLastIdIsUnreadable() throws {
        var data = v6Header()
        let item = textItem(CrdtID(author: 1, counter: .max - 1), text: "abc")
        data.append(contentsOf: blockBytes(type: 0x07, body: rootTextBody(items: item, count: 1)))
        let page = try parseRM(data)
        #expect(page.unreadableBlocks == 1)
        #expect(page.text == nil)
    }

    /// A later tree-node block without anchor fields unanchors the group.
    @Test func aTreeNodeWithoutAnAnchorClearsIt() throws {
        func lww(_ tagIndex: UInt64, _ value: [UInt8]) -> [UInt8] {
            let body = idBytes(1, CrdtID(author: 1, counter: 999)) + value
            return subblockHeaderBytes(tagIndex, length: body.count) + body
        }
        let label = varuintBytes(1) + [1] + Array("g".utf8)
        let plain = idBytes(1, CrdtID(author: 0, counter: 20))
            + lww(2, subblockHeaderBytes(2, length: label.count) + label)
            + lww(3, varuintBytes(2 << 4 | 0x1) + [1])
        var data = try Fixtures.anchors("nested-anchors")
        data.append(contentsOf: blockBytes(type: 0x02, version: 2, body: plain))
        let page = try parseRM(data)
        #expect(page.unreadableBlocks == 0)
        let offsets = Dictionary(uniqueKeysWithValues: page.strokes.map { ($0.points[0].x, [$0.anchorOffset.x, $0.anchorOffset.y]) })
        #expect(offsets == [1: [0, 0], 2: [5, 482], 3: [7, 0]])
    }

    /// A deleted run claiming four billion characters must not be expanded.
    @Test func aHugeDeletedTextRunIsUnreadableNotAllocated() throws {
        let fields = idBytes(2, CrdtID(author: 1, counter: 1)) + idBytes(3, .end) + idBytes(4, .end) + intBytes(5, .max)
        let item = subblockHeaderBytes(0, length: fields.count) + fields
        var data = v6Header()
        data.append(contentsOf: blockBytes(type: 0x07, body: rootTextBody(items: item, count: 1)))
        let page = try parseRM(data)
        #expect(page.unreadableBlocks == 1)
        #expect(page.text == nil)
    }

    /// A text list longer than the bytes left in its block is refused up front.
    @Test func aTextItemCountPastTheBlockIsUnreadable() throws {
        var data = v6Header()
        data.append(contentsOf: blockBytes(type: 0x07, body: rootTextBody(items: [], count: .max)))
        #expect(try parseRM(data).unreadableBlocks == 1)
    }

    /// A text block cut short anywhere costs the text, not the page.
    @Test func aTruncatedTextBlockIsCountedNotTrapped() throws {
        let data = try Fixtures.data("Normal_AB", "rm")
        var offset = 43, textBlock: Range<Int>?
        while offset + 8 <= data.count {
            let length = Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
            if data[offset + 7] == 0x07 { textBlock = offset + 8..<offset + 8 + length }
            offset += 8 + length
        }
        let body = try #require(textBlock)
        for cut in 1..<body.count {
            var hostile = v6Header()
            hostile.append(contentsOf: blockBytes(type: 0x07, body: Array(data[body.lowerBound..<body.lowerBound + cut])))
            let page = try parseRM(hostile)
            #expect(page.unreadableBlocks == 1 && page.text == nil, "cut at \(cut)")
        }
    }

    /// A later tree-node block hiding the layer the highlights sit on hides them too.
    @Test func aHighlightOnAHiddenLayerIsDropped() throws {
        func lww(_ tagIndex: UInt64, _ value: [UInt8]) -> [UInt8] {
            let body = idBytes(1, CrdtID(author: 1, counter: 999)) + value
            return subblockHeaderBytes(tagIndex, length: body.count) + body
        }
        let label = varuintBytes(7) + [1] + Array("Layer 1".utf8)
        let hide = idBytes(1, CrdtID(author: 0, counter: 11))
            + lww(2, subblockHeaderBytes(2, length: label.count) + label)
            + lww(3, varuintBytes(2 << 4 | 0x1) + [0])
        var data = try Fixtures.data("Wikipedia_highlighted_p1", "rm")
        #expect(normalize(try parseRM(data), orientation: .portrait).highlights.count == 4)
        data.append(contentsOf: blockBytes(type: 0x02, body: hide))
        let page = try parseRM(data)
        #expect(page.unreadableBlocks == 0)
        #expect(page.highlights.count == 4 && page.highlights.allSatisfy(\.hidden))
        #expect(normalize(page, orientation: .portrait).highlights.isEmpty)
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

    @Test func aHighlightsOwnColourWins() throws {
        let page = try parseRM(try Fixtures.data("Color_and_tool_v3.14.4", "rm"))
        #expect(page.highlights.first?.colorRgba == 0xff_ff_ed_75) // tag 10
        let ink = normalize(page, orientation: .portrait)
        #expect(ink.highlights.first?.style.color == "#ffed75")
        #expect(ink.highlights.first?.style.opacity == 0.35)
    }
}

@Suite struct RootTextTests {
    @Test func readsParagraphsAndTheirStyles() throws {
        let page = try parseRM(try Fixtures.data("Bold_Heading_Bullet_Normal", "rm"))
        #expect(page.unreadableBlocks == 0)
        let text = try #require(page.text)
        #expect(text.paragraphs.map(\.text) == ["A", "new line", "B is a letter of the alphabet", "C"])
        #expect(text.paragraphs.map(\.style) == [.bold, .heading, .bullet, .plain])
        #expect(text.x == -468 && text.y == 234 && text.width == 936)
    }

    @Test func ordersTextLikeRmscene() throws {
        #expect(try parseRM(try Fixtures.data("Normal_AB", "rm")).text?.paragraphs.map(\.text) == ["AB"])
        // two authors typed between A and Z at once; the higher author goes first
        let concurrent = try #require(try parseRM(try Fixtures.data("test-crdt-ordering", "rm")).text)
        #expect(concurrent.paragraphs.map(\.text) == ["A12_Z"])
        #expect(concurrent.paragraphs.map(\.style) == [.heading])
        // inline bold and italic codes are dropped from the text
        let inline = try #require(try parseRM(try Fixtures.data("Normal_A_stroke_2_layers_v3.3.2", "rm")).text)
        #expect(inline.paragraphs.map(\.text) == [
            "A", "v3.2.2", "Normal bold italic", "Bold italic normal", "Bold line", "Normal line", "Heading line",
        ])
    }

    @Test func aPageWithoutTypedTextHasNone() throws {
        #expect(try parseRM(try Fixtures.data("Color_and_tool_v3.14.4", "rm")).text == nil)
    }

    /// Each group moves by its anchor's origin x and the laid-out y of its
    /// anchor character's paragraph: the first at 234 - 88, then down by 70.
    @Test func anAnchoredGroupMovesWithItsCharactersLine() throws {
        let page = try parseRM(try Fixtures.data("Normal_A_stroke_2_layers_v3.3.2", "rm"))
        #expect(page.unreadableBlocks == 0)
        let offsets = page.strokes.map { [$0.anchorOffset.x, $0.anchorOffset.y] }
        #expect(offsets.contains([-464, 146])) // on "A", the first paragraph
        #expect(offsets.contains([-396.59375, 216])) // on the last "2" of "v3.2.2", the second
        #expect(offsets.contains([-221.203125, 286])) // inside "Normal bold italic", the third
        #expect(!offsets.contains([0, 0])) // every stroke here is in an anchored group
        let first = try #require(page.strokes.first { $0.anchorOffset == (-464, 146) })
        let ink = normalize(page, orientation: .portrait)
        let point = try #require(ink.strokes.first { $0.id == first.id }?.points.first)
        #expect(point.x == first.points[0].x - 464 + 702 && point.y == first.points[0].y + 146)
    }

    /// rmscene + rmc made this page (see Fixtures/anchors): a group anchored to a
    /// deleted character holding one anchored to "Y", and one anchored to an id
    /// the text doesn't have. Offsets are rmc's for the strokes.
    @Test func anchorsFollowRmcThroughDeletedCharsNestingAndUnknownIds() throws {
        let page = try parseRM(try Fixtures.anchors("nested-anchors"))
        #expect(page.unreadableBlocks == 0)
        let text = try #require(page.text)
        #expect(text.paragraphs.map(\.text) == ["Hi", "Yo"])
        #expect(text.paragraphs.map(\.style) == [.plain, .heading])
        #expect(text.paragraphs[0].charIDs.count == 5) // "Hi" and three deleted
        let offsets = Dictionary(uniqueKeysWithValues: page.strokes.map { ($0.points[0].x, [$0.anchorOffset.x, $0.anchorOffset.y]) })
        #expect(offsets == [1: [10, 412], 2: [15, 894], 3: [7, 0]])
        // ours, not rmc's (it draws no highlights): a highlight moves with its group
        #expect(page.highlights.map { [$0.anchorOffset.x, $0.anchorOffset.y] } == [[10, 412]])
        let ink = normalize(page, orientation: .portrait)
        #expect(ink.highlights.first?.rects.first?.origin == CGPoint(x: 4 + 10 + 702, y: 6 + 412))
    }

    @Test func everyParagraphStartAndTheTextsEndsAreAnchors() throws {
        let text = try #require(try parseRM(try Fixtures.anchors("nested-anchors")).text)
        let anchors = text.anchors()
        #expect(anchors[.end] == 412) // the first paragraph opens without a newline
        #expect(anchors[CrdtID(author: 1, counter: 30)] == 482) // the newline opening "Yo"
        #expect(anchors[RootText.bottomAnchor] == 632) // under the heading's 150
        #expect(anchors[RootText.topAnchor] == 500 + 33.59375)
        #expect(RootText.anchors(nil, pageHeight: 1872) == [RootText.topAnchor: 0, RootText.bottomAnchor: 1872])
    }

    @Test func normalizeLaysOutOneBaselinePerParagraph() throws {
        let ink = normalize(try parseRM(try Fixtures.data("Bold_Heading_Bullet_Normal", "rm")), orientation: .portrait)
        // tops 146, 216, 366, 401; each baseline one line height (70, 150, 35, 70) further down
        #expect(ink.text == [
            TextLine(style: .bold, text: "A", x: 234, y: 216),
            TextLine(style: .heading, text: "new line", x: 234, y: 366),
            TextLine(style: .bullet, text: "B is a letter of the alphabet", x: 234, y: 401),
            TextLine(style: .plain, text: "C", x: 234, y: 471),
        ])
    }
}
