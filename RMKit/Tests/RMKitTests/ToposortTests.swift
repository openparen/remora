import Testing
@testable import RMKit

@Suite struct ToposortTests {
    struct Item { let id, left, right: CrdtID }
    func c(_ n: UInt64, author: UInt8 = 1) -> CrdtID { CrdtID(author: author, counter: n) }

    @Test func followsNeighbourLinks() {
        let items = [
            Item(id: c(3), left: c(2), right: .end),
            Item(id: c(1), left: .end, right: c(2)),
            Item(id: c(2), left: c(1), right: c(3)),
        ]
        let order = Toposort.order(items, id: \.id, left: \.left, right: \.right)
        #expect(order.map(\.id.counter) == [1, 2, 3])
    }

    @Test func concurrentInsertsPutTheHigherAuthorFirst() {
        let items = [
            Item(id: c(5, author: 1), left: .end, right: .end),
            Item(id: c(5, author: 2), left: .end, right: .end),
        ]
        let order = Toposort.order(items, id: \.id, left: \.left, right: \.right)
        #expect(order.map(\.id.author) == [2, 1])
    }
}
