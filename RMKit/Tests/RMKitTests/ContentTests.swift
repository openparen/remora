import Foundation
import Testing
@testable import RMKit

@Suite struct ContentTests {
    @Test func decodesBothSchemasAndBothTagShapes() throws {
        let json = """
            {"fileType":"pdf","orientation":"landscape","pageCount":2,"pages":null,
             "cPages":{"pages":[{"id":"p1","idx":{"timestamp":"1:1","value":"ba"},"redir":{"timestamp":"1:1","value":0},
                                 "template":{"timestamp":"1:1","value":"P Grid medium"}},
                                {"id":"p2","idx":{"timestamp":"1:1","value":"bb"},"deleted":{"timestamp":"1:1","value":1}}]},
             "tags":[{"name":"work","timestamp":1},"legacy"]}
            """
        let content = try JSONDecoder().decode(DocumentContent.self, from: Data(json.utf8))
        #expect(content.fileType == "pdf")
        #expect(content.orientation == .landscape)
        #expect(content.pages == nil)
        #expect(content.cPages.map(\.id) == ["p1", "p2"])
        #expect(content.cPages[0].template == "P Grid medium")
        #expect(content.cPages[0].redir == 0)
        #expect(content.cPages[1].deleted)
        #expect(content.tags == ["work", "legacy"])
    }

    @Test func aBadFieldCostsOnlyThatField() throws {
        let content = try JSONDecoder().decode(DocumentContent.self, from: Data(#"{"pageCount":"many","orientation":"portrait"}"#.utf8))
        #expect(content.pageCount == nil)
        #expect(content.orientation == .portrait)
    }

    @Test func metadataNeedsOnlyNameParentAndType() throws {
        let meta = try JSONDecoder().decode(ItemMetadata.self, from: Data(#"{"visibleName":"N","parent":"","type":"DocumentType"}"#.utf8))
        #expect(!meta.pinned)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ItemMetadata.self, from: Data(#"{"visibleName":"N","type":"DocumentType"}"#.utf8))
        }
    }
}
