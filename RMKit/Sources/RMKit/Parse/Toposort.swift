/// Order CRDT sequence items by their left/right neighbour links, breaking
/// ties the way rmapi-js does: higher author first, then lower counter.
/// Items a cycle keeps from being placed are appended in input order.
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

        func rank(_ node: Int) -> (Int, UInt64) {
            if node == start { return (Int.min, 0) }
            if node == end { return (Int.max, UInt64.max) }
            let crdt = id(items[node])
            return (-Int(crdt.author), crdt.counter)
        }

        // ponytail: linear scan of the ready set; it holds one or two nodes on real pages
        var ready = Set((0..<count + 2).filter { inDegree[$0] == 0 })
        var placed = Array(repeating: false, count: count + 2)
        var order: [T] = []
        order.reserveCapacity(count)
        while let best = ready.min(by: { rank($0) < rank($1) }) {
            ready.remove(best)
            placed[best] = true
            if best < count { order.append(items[best]) }
            for next in successors[best] {
                inDegree[next] -= 1
                if inDegree[next] == 0 { ready.insert(next) }
            }
        }
        if order.count < count {
            for i in 0..<count where !placed[i] { order.append(items[i]) }
        }
        return order
    }
}
