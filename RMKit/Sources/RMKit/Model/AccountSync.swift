import Foundation

/// One account's library: read from the cache at once, refreshed from the
/// cloud on demand. The last root hash is kept beside the cache, so the app
/// can open offline with whatever it has seen.
public actor AccountSync {
    public nonisolated let account: String
    public nonisolated let blobs: BlobStore
    /// The account's cloud session; nil in tests that fake the cloud.
    public nonisolated let session: CloudSession?
    private let offline: BlobStore
    private let latestRoot: @Sendable () async throws -> RootHash
    private let rootFile: URL
    public private(set) var library: Library?
    private var lastTrim: ContinuousClock.Instant?

    public init(account: String, session: CloudSession) {
        let directory = BlobCache.directory(account: account)
        self.init(
            account: account, directory: directory, session: session,
            root: { try await session.root() },
            fetch: { try await session.file(hash: $0, name: $1) })
    }

    /// `directory` is the blob cache; the root hash is stored next to it.
    init(account: String, directory: URL, session: CloudSession? = nil, verifyHashes: Bool = true,
         root: @escaping @Sendable () async throws -> RootHash, fetch: @escaping BlobStore.Fetch) {
        self.account = account
        self.session = session
        let cache = BlobCache(directory: directory)
        blobs = BlobStore(cache: cache, verifyHashes: verifyHashes, fetch: fetch)
        offline = BlobStore(cache: cache, verifyHashes: verifyHashes) { _, _ in throw CloudError.offline }
        latestRoot = root
        rootFile = directory.deletingLastPathComponent().appending(path: "root.json")
    }

    /// The library as last synced, from the cache alone; nil if nothing usable is cached.
    public func loadCached() async -> Library? {
        guard library == nil else { return library }
        guard let data = try? Data(contentsOf: rootFile),
              let root = try? JSONDecoder().decode(RootHash.self, from: data),
              let cached = try? await Library.build(root: root, blobs: offline)
        else { return library }
        // a refresh may have finished while the cache was read; never replace it with older data
        if library == nil { library = cached }
        return library
    }

    /// Re-read the root and rebuild what changed. Throws without touching the
    /// current library when the cloud can't be read.
    public func refresh() async throws -> Library {
        let root = try await latestRoot()
        // opening documents grows the cache even when the root doesn't change; a trim walks the
        // whole cache, so at most every ten minutes, not on every 30 s poll
        defer {
            if lastTrim.map({ $0.duration(to: .now) > .seconds(600) }) ?? true {
                lastTrim = .now
                try? blobs.cache.evict()
            }
        }
        if let library, library.root == root, library.failures.isEmpty { return library }
        let fresh = try await Library.build(root: root, previous: library, blobs: blobs)
        library = fresh
        // best effort: without it the next launch just starts from an older root
        try? FileManager.default.createDirectory(at: rootFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(root).write(to: rootFile, options: .atomic)
        return fresh
    }
}
