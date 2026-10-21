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

    @Test func sameAuthorSortsByLowerCounterFirst() {
        let items = [
            Item(id: c(9), left: .end, right: .end),
            Item(id: c(3), left: .end, right: .end),
            Item(id: c(5), left: .end, right: .end),
        ]
        let order = Toposort.order(items, id: \.id, left: \.left, right: \.right)
        #expect(order.map(\.id.counter) == [3, 5, 9])
    }

    @Test func unknownLeftReferenceFallsBackToStart() {
        let unknown = CrdtID(author: 9, counter: 999)
        let items = [
            Item(id: c(1), left: unknown, right: .end),
            Item(id: c(2), left: .end, right: .end),
        ]
        let order = Toposort.order(items, id: \.id, left: \.left, right: \.right)
        #expect(order.map(\.id.counter) == [1, 2])
    }

    @Test func cycleFallbackAppendsUnplacedItemsInInputOrder() {
        let a = c(1), b = c(2)
        let items = [
            Item(id: a, left: b, right: .end),
            Item(id: b, left: a, right: .end),
        ]
        let order = Toposort.order(items, id: \.id, left: \.left, right: \.right)
        #expect(order.map(\.id.counter) == [1, 2])
    }

    @Test func manySimultaneousItemsSortQuicklyAndCorrectly() {
        let items = (0..<20000).map { i in
            Item(id: c(UInt64(i), author: UInt8(1 + i % 3)), left: .end, right: .end)
        }
        let expected = items.sorted { lhs, rhs in
            lhs.id.author != rhs.id.author ? lhs.id.author > rhs.id.author : lhs.id.counter < rhs.id.counter
        }
        let clock = ContinuousClock()
        let start = clock.now
        let order = Toposort.order(items, id: \.id, left: \.left, right: \.right)
        let elapsed = clock.now - start
        #expect(order.map(\.id) == expected.map(\.id))
        #expect(elapsed < .seconds(2))
    }
}
