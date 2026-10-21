/// Order CRDT sequence items by their left/right neighbour links, breaking
/// ties the way rmapi-js does: higher author first, then lower counter, then
/// (for two items placed at the exact same rank) input order, so the result
/// is always deterministic even for a file with duplicate ids.
/// Items a cycle keeps from being placed are appended in input order.
///
/// ponytail: deleted items are dropped before this ever sees them, as
/// rmapi-js does, so a deletion is never an ordering anchor here. rmscene
/// keeps tombstones around as anchors instead; that only matters once this
/// port stops tracking rmapi-js's behaviour exactly.
enum Toposort {
    static func order<T>(
        _ items: [T],
        id: (T) -> CrdtID,
        left: (T) -> CrdtID,
        right: (T) -> CrdtID
    ) -> [T] {
        guard items.count > 1 else { return items }
        let count = items.count
        let start = count
        let end = count + 1

        var index: [CrdtID: Int] = [:]
        for (i, item) in items.enumerated() { index[id(item)] = i }
        func resolve(_ ref: CrdtID, _ fallback: Int) -> Int {
            ref == .end ? fallback : index[ref] ?? fallback
        }

        var successors = Array(repeating: [Int](), count: count + 2)
        var inDegree = Array(repeating: 0, count: count + 2)
        for (i, item) in items.enumerated() {
            let from = resolve(left(item), start)
            successors[from].append(i)
            inDegree[i] += 1
            let to = resolve(right(item), end)
            successors[i].append(to)
            inDegree[to] += 1
        }

        // The node index breaks ties between two items that would otherwise
        // rank identically (duplicate ids), so the order is deterministic.
        func rank(_ node: Int) -> (Int, UInt64, Int) {
            if node == start { return (Int.min, 0, node) }
            if node == end { return (Int.max, UInt64.max, node) }
            let crdt = id(items[node])
            return (-Int(crdt.author), crdt.counter, node)
        }

        // The ready set as an array sorted descending by rank, so the next
        // item to place is always the last element (`popLast` is O(1)); a
        // newly-ready node is inserted by binary search. This replaces an
        // O(n) linear scan of the whole ready set on every pop, which made
        // ordering quadratic whenever many items become ready at once (e.g.
        // a layer whose items were all written by one author in one pass).
        func insert(_ node: Int, into array: inout [Int]) {
            let r = rank(node)
            var lo = 0, hi = array.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if r < rank(array[mid]) {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            array.insert(node, at: lo)
        }

        var ready = (0..<count + 2).filter { inDegree[$0] == 0 }.sorted { rank($1) < rank($0) }
        var placed = Array(repeating: false, count: count + 2)
        var order: [T] = []
        order.reserveCapacity(count)
        while let best = ready.popLast() {
            placed[best] = true
            if best < count { order.append(items[best]) }
            for next in successors[best] {
                inDegree[next] -= 1
                if inDegree[next] == 0 { insert(next, into: &ready) }
            }
        }
        if order.count < count {
            for i in 0..<count where !placed[i] { order.append(items[i]) }
        }
        return order
    }
}
