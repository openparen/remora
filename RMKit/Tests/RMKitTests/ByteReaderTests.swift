import Foundation
import Testing
@testable import RMKit

@Suite struct ByteReaderTests {
    @Test func readsVaruintsAndTags() throws {
        // 150 as a varuint, then tag 2/byte4 (0x24) holding 7
        let r = ByteReader(Data([0x96, 0x01, 0x24, 7, 0, 0, 0]))
        #expect(try r.varuint() == 150)
        #expect(r.hasTag(2, .byte4))
        #expect(!r.hasTag(3, .byte4))
        #expect(try r.int(2) == 7)
        #expect(r.atEnd)
    }

    @Test func subblockMustBeConsumed() {
        // tag 1/length4 (0x1c), length 2, then two bytes
        let r = ByteReader(Data([0x1c, 2, 0, 0, 0, 0xaa, 0xbb]))
        #expect(throws: RMParseError.subblockNotConsumed(index: 1)) { try r.subblock(1) { try r.u8() } }
    }

    @Test func subblockEndsWhereItsLengthSays() throws {
        let r = ByteReader(Data([0x1c, 2, 0, 0, 0, 0xaa, 0xbb, 0xcc]))
        #expect(try r.subblock(1) { [try r.u8(), try r.u8()] } == [0xaa, 0xbb])
        #expect(try r.u8() == 0xcc)
    }
}
