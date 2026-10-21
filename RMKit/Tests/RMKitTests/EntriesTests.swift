import Foundation
import Testing
@testable import RMKit

@Suite struct EntriesTests {
    @Test func parsesSchema3() throws {
        let text = "3\n\(fakeHash(1)):0:doc.content:0:12\n\(fakeHash(2)):0:doc/p1.rm:0:400\n"
        let entries = try Entries.parse(Data(text.utf8))
        #expect(entries.map(\.id) == ["doc.content", "doc/p1.rm"])
        #expect(entries[1].size == 400)
    }

    @Test func parsesSchema4AndChecksTheCount() throws {
        let good = "4\n0:.:1:5\n\(fakeHash(3)):0:doc-id:4:5\n"
        #expect(try Entries.parse(Data(good.utf8)).map(\.id) == ["doc-id"])
        let bad = "4\n0:.:2:5\n\(fakeHash(3)):0:doc-id:4:5\n"
        #expect(throws: CloudError.self) { try Entries.parse(Data(bad.utf8)) }
    }

    @Test func rejectsABadHash() {
        #expect(throws: CloudError.self) { try Entries.parse(Data("3\nnothex:0:a:0:1\n".utf8)) }
    }
}
