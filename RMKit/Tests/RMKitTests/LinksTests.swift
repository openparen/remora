import Foundation
import Testing
@testable import RMKit

@Suite struct LinksTests {
    let doc = "36965769-1619-48ce-8928-84b9dde8b756", page = "4d9c3a99-a415-46eb-adb6-5553e934a08d"

    @Test func roundTrips() {
        for link in [RemoraLink.document(id: doc, page: nil), .document(id: doc, page: page), .folder(id: doc)] {
            #expect(RemoraLink(link.url) == link)
        }
        #expect(RemoraLink.document(id: doc, page: page).url.absoluteString == "rmr://doc/\(doc)?page=\(page)")
    }

    @Test func refusesAnythingElse() {
        for text in ["https://doc/\(doc)", "rmr://doc/", "rmr://doc/a/b", "rmr://doc/../x", "rmr://doc/\(doc)?page=../x",
                     "rmr://shelf/\(doc)", "rmr://doc/%2e%2e"] {
            #expect(RemoraLink(URL(string: text)!) == nil, "\(text)")
        }
    }

    @Test func markdownEscapesBrackets() {
        let link = RemoraLink.document(id: doc, page: page)
        #expect(link.markdown(title: "Notes [draft]", pageNumber: 12) == "[Notes \\[draft\\] p.12](rmr://doc/\(doc)?page=\(page))")
    }

    @Test func refusesOverlongIdsAndEscapesBackslashes() {
        #expect(RemoraLink(URL(string: "rmr://doc/\(String(repeating: "a", count: 65))")!) == nil)
        #expect(RemoraLink.document(id: doc, page: nil).markdown(title: "a\\b\nc") == "[a\\\\b c](rmr://doc/\(doc))")
    }
}
