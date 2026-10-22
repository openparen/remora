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
            CPage(id: "d", idx: "z", redir: -1),
        ])
        let pages = PageMap.pages(content: content, rmPageIDs: [])
        #expect(pages.map(\.id) == ["a", "b", "c", "d"])
        #expect(pages.map(\.number) == [1, 2, 3, 4])
        #expect(pages[2].sourcePage == 5)
        #expect(pages[0].sourcePage == nil)
        #expect(pages[1].template == "P Lines small")
        #expect(pages[3].sourcePage == nil)
    }

    @Test func legacyPagesUseTheRedirectionMap() {
        let mapped = PageMap.pages(content: DocumentContent(pages: ["x", "y", "z"], redirectionPageMap: [0, -1, 1]), rmPageIDs: [])
        #expect(mapped.map(\.sourcePage) == [1, nil, 2])
        let identity = PageMap.pages(content: DocumentContent(pages: ["x", "y"]), rmPageIDs: [])
        #expect(identity.map(\.sourcePage) == [1, 2])
    }

    /// What reMarkable's server writes for an upload the tablet hasn't opened yet: one page, whatever the PDF holds.
    static let freshUpload = #"{"fileType":"pdf","formatVersion":1,"originalPageCount":1,"pageCount":1,"pages":["p1"],"redirectionPageMap":[0]}"#

    func document(_ content: DocumentContent) -> Document {
        Document(id: "d", files: [], content: content, pages: PageMap.pages(content: content, rmPageIDs: []))
    }

    @Test func aFreshUploadCoversTheWholePDFWithPagesThatHaveNoLinksYet() throws {
        let content = try JSONDecoder().decode(DocumentContent.self, from: Data(Self.freshUpload.utf8))
        let covered = document(content).coveringSource(pageCount: 3)
        #expect(covered.pages.map(\.number) == [1, 2, 3])
        #expect(covered.pages.map(\.sourcePage) == [1, 2, 3])
        #expect(covered.pages.map(\.provisional) == [true, true, true])
        #expect(Set(covered.pages.map(\.id)).count == 3)
        // a one-page PDF looks the same whether or not the tablet opened it: left as it is
        #expect(document(content).coveringSource(pageCount: 1).pages.map(\.provisional) == [false])
    }

    @Test func aPageListTheTabletWroteIsLeftAlone() throws {
        // one page shown of a three-page PDF on purpose: the other two were deleted on the tablet
        let tablet = document(DocumentContent(cPages: [CPage(id: "a", idx: "a", redir: 0)])).coveringSource(pageCount: 3)
        #expect(tablet.pages.map(\.id) == ["a"])
        #expect(!tablet.pages[0].provisional)
        let legacy = #"{"fileType":"pdf","originalPageCount":3,"pageCount":1,"pages":["a"],"redirectionPageMap":[0]}"#
        let trimmed = document(try JSONDecoder().decode(DocumentContent.self, from: Data(legacy.utf8))).coveringSource(pageCount: 3)
        #expect(trimmed.pages.map(\.id) == ["a"])
        #expect(!trimmed.pages[0].provisional)
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

        let badCPage = try content(
            #"{"cPages":{"pages":[{"id":"a","idx":{"timestamp":"1:1","value":"ba"}}, "oops", {"id":"b","idx":{"timestamp":"1:1","value":"bb"}}]}}"#)
        #expect(PageMap.pages(content: badCPage, rmPageIDs: []).map(\.number) == [1, 3])
    }

    @Test func aCPageWithNoIdxStaysAfterThePageBeforeIt() throws {
        func content(_ json: String) throws -> DocumentContent {
            try JSONDecoder().decode(DocumentContent.self, from: Data(json.utf8))
        }

        // the placeholder (no idx) must number right after "a", not sort first as ""
        let withPlaceholder = try content(
            #"{"cPages":{"pages":[{"id":"a","idx":{"timestamp":"1:1","value":"ba"}}, "oops", {"id":"b","idx":{"timestamp":"1:1","value":"bb"}}]}}"#)
        let pages = PageMap.pages(content: withPlaceholder, rmPageIDs: [])
        #expect(pages.map(\.id) == ["a", "b"])
        #expect(pages.map(\.number) == [1, 3])

        // a page with a real idx but no id, between two others, still keeps its number
        let withIdlessPage = try content(
            #"""
            {"cPages":{"pages":[{"id":"x","idx":{"timestamp":"1:1","value":"xa"}},
                                 {"idx":{"timestamp":"1:1","value":"xb"}},
                                 {"id":"y","idx":{"timestamp":"1:1","value":"xc"}}]}}
            """#)
        let idlessPages = PageMap.pages(content: withIdlessPage, rmPageIDs: [])
        #expect(idlessPages.map(\.id) == ["x", "y"])
        #expect(idlessPages.map(\.number) == [1, 3])
    }
}
