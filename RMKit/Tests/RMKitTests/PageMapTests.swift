import Foundation
import Testing
@testable import RMKit

@Suite struct PageMapTests {
    @Test func cPagesSortByIdxBytewiseAndSkipDeleted() {
        let content = DocumentContent(cPages: [
            CPage(id: "c", idx: "bc", redir: 4),
            CPage(id: "gone", idx: "ba", deleted: true),
            CPage(id: "a", idx: "B"), // a real byte-wise check: "B" (0x42) < "a" (0x61) < "bc"
            CPage(id: "b", idx: "a", template: "P Lines small"),
        ])
        let pages = PageMap.pages(content: content, rmPageIDs: [])
        #expect(pages.map(\.id) == ["a", "b", "c"])
        #expect(pages.map(\.number) == [1, 2, 3])
        #expect(pages[2].sourcePage == 5)
        #expect(pages[0].sourcePage == nil)
        #expect(pages[1].template == "P Lines small")
    }

    @Test func legacyPagesUseTheRedirectionMap() {
        let mapped = PageMap.pages(content: DocumentContent(pages: ["x", "y", "z"], redirectionPageMap: [0, -1, 1]), rmPageIDs: [])
        #expect(mapped.map(\.sourcePage) == [1, nil, 2])
        let identity = PageMap.pages(content: DocumentContent(pages: ["x", "y"]), rmPageIDs: [])
        #expect(identity.map(\.sourcePage) == [1, 2])
    }

    @Test func noPageListFallsBackToTheInkFilesAndPagedata() {
        let pages = PageMap.pages(content: DocumentContent(pages: []), rmPageIDs: ["p1", "p2"], pagedata: ["Blank", "P Dots large"])
        #expect(pages.map(\.id) == ["p1", "p2"])
        #expect(pages.map(\.template) == ["Blank", "P Dots large"])
    }

    @Test func aBadElementKeepsItsSlot() throws {
        func content(_ json: String) throws -> DocumentContent {
            try JSONDecoder().decode(DocumentContent.self, from: Data(json.utf8))
        }

        let badPage = try content(#"{"pages":["x", 5, "z"]}"#)
        let pages = PageMap.pages(content: badPage, rmPageIDs: [])
        #expect(pages.map(\.id) == ["x", "z"])
        #expect(pages.map(\.number) == [1, 3])

        let nullRedir = try content(#"{"pages":["a","b","c"],"redirectionPageMap":[0, null, 1]}"#)
        #expect(PageMap.pages(content: nullRedir, rmPageIDs: []).map(\.sourcePage) == [1, nil, 2])

        let garbageRedir = try content(#"{"pages":["a","b"],"redirectionPageMap":"garbage"}"#)
        #expect(PageMap.pages(content: garbageRedir, rmPageIDs: []).map(\.sourcePage) == [nil, nil])

        let badCPage = try content(#"{"cPages":{"pages":[{"id":"a"}, "oops", {"id":"b"}]}}"#)
        #expect(PageMap.pages(content: badCPage, rmPageIDs: []).map(\.number) == [1, 3])
    }
}
