import Foundation
import Testing
@testable import RMKit

@Suite struct LinksTests {
    let doc = "d87aba33-e57c-438b-8d0a-91ace808f9a9", page = "3f41ce80-261d-4b4b-a73d-386fd2d36535"

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
}
