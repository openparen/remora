import CryptoKit
import Foundation

/// Content-addressed blobs on disk. A hash names its bytes forever, so nothing
/// is ever invalidated. Entry lists, metadata and content live in `keep/` and
/// are never evicted; page ink and documents live in `lru/` and are trimmed,
/// least recently read first, once they pass the limit.
public struct BlobCache: Sendable {
    public let directory: URL
    public let limit: Int

    public init(directory: URL, limit: Int = 2 << 30) {
        self.directory = directory
        self.limit = limit
    }

    /// `~/Library/Caches/Remora/<account>/blobs`
    public static func directory(account: String) -> URL {
        let safe = String(account.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return URL.cachesDirectory.appending(path: "Remora/\(safe)/blobs")
    }

    static func isEvictable(name: String) -> Bool {
        name.hasSuffix(".rm") || name.hasSuffix(".pdf") || name.hasSuffix(".epub")
    }

    private func url(hash: String, name: String) -> URL {
        directory
            .appending(path: Self.isEvictable(name: name) ? "lru" : "keep")
            .appending(path: String(hash.prefix(2)))
            .appending(path: hash)
    }

    public func data(hash: String, name: String) -> Data? {
        guard Entries.isHash(hash) else { return nil }
        let url = url(hash: hash, name: name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        if Self.isEvictable(name: name) {
            // the modification date is the LRU clock
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path())
        }
        return data
    }

    public func store(_ data: Data, hash: String, name: String) throws {
        guard Entries.isHash(hash) else { throw CloudError.malformed("not a hash: \(hash)") }
        let url = url(hash: hash, name: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Trim `lru/` to the limit, oldest first.
    public func evict() throws {
        let root = directory.appending(path: "lru")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        var files: [(url: URL, date: Date, size: Int)] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0))
        }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files.sorted(by: { $0.date < $1.date }) where total > limit {
            // a concurrent atomic write can make a file vanish mid-trim; don't abort the trim for it
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }
}

/// Cache in front of a fetch. The fetch is a closure so tests and offline mode
/// can stand in for the cloud. Concurrent requests for one hash share a fetch,
/// and at most `maxConcurrentFetches` run at once, so a screen of thumbnails
/// can't flood the cloud.
public struct BlobStore: Sendable {
    public typealias Fetch = @Sendable (_ hash: String, _ name: String) async throws -> Data

    public let cache: BlobCache
    let fetch: Fetch
    let verifyHashes: Bool
    private let gate: FetchGate

    /// `verifyHashes` checks each file against its name before caching it, so a
    /// captive portal or proxy can't plant bytes under a hash forever. Entry
    /// lists are exempt: schema 3 hashes them as their children's hashes.
    public init(cache: BlobCache, maxConcurrentFetches: Int = 8, verifyHashes: Bool = true, fetch: @escaping Fetch) {
        self.cache = cache
        self.fetch = fetch
        self.verifyHashes = verifyHashes
        gate = FetchGate(limit: maxConcurrentFetches)
    }

    public func data(hash: String, name: String) async throws -> Data {
        if let data = cache.data(hash: hash, name: name) { return data }
        return try await gate.run(key: hash) { [cache, fetch, verifyHashes] in
            let data = try await fetch(hash, name)
            if verifyHashes, !name.hasSuffix(".docSchema") {
                let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard actual == hash else { throw CloudError.malformed("\(name) does not match its hash") }
            }
            try cache.store(data, hash: hash, name: name)
            return data
        }
    }

    public func entries(hash: String, id: String) async throws -> [Entry] {
        try Entries.parse(try await data(hash: hash, name: "\(id).docSchema"))
    }
}

/// Shares one in-flight task per key and bounds how many run at once.
actor FetchGate {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var inFlight: [String: Task<Data, Error>] = [:]

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    func run(key: String, _ work: @escaping @Sendable () async throws -> Data) async throws -> Data {
        if let task = inFlight[key] { return try await task.value }
        let task = Task { try await self.limited(work) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    private func limited(_ work: @Sendable () async throws -> Data) async throws -> Data {
        while running >= limit { await withCheckedContinuation { waiting.append($0) } }
        running += 1
        defer {
            running -= 1
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        return try await work()
    }
}
