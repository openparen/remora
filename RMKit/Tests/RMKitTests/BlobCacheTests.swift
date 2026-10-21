import Foundation
import Testing
@testable import RMKit

@Suite struct BlobCacheTests {
    @Test func roundTripsAndEvictsOldestInkFirst() throws {
        let cache = BlobCache(directory: temporaryDirectory(), limit: 10)
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        try cache.store(Data("keep-me-forever".utf8), hash: fakeHash(1), name: "doc.content")
        for n in 2...4 { try cache.store(Data("123456".utf8), hash: fakeHash(n), name: "doc/p\(n).rm") }
        // make p2 the oldest and p4 the newest
        for n in 2...4 {
            let url = cache.directory.appending(path: "lru/00/\(fakeHash(n))")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(n))], ofItemAtPath: url.path())
        }
        try cache.evict()
        #expect(cache.data(hash: fakeHash(1), name: "doc.content") != nil)
        #expect(cache.data(hash: fakeHash(2), name: "doc/p2.rm") == nil)
        #expect(cache.data(hash: fakeHash(3), name: "doc/p3.rm") == nil)
        #expect(cache.data(hash: fakeHash(4), name: "doc/p4.rm") != nil)
    }

    @Test func storeFetchesOnceThenServesFromDisk() async throws {
        let fetches = Locked(0)
        let store = BlobStore(cache: BlobCache(directory: temporaryDirectory())) { _, _ in
            fetches.update { $0 += 1 }
            return Data("x".utf8)
        }
        defer { try? FileManager.default.removeItem(at: store.cache.directory) }
        _ = try await store.data(hash: fakeHash(1), name: "a.content")
        _ = try await store.data(hash: fakeHash(1), name: "a.content")
        #expect(fetches.value == 1)
    }

    @Test func onlyEverBuildsPathsFromValidHashes() throws {
        let cache = BlobCache(directory: temporaryDirectory(), limit: 10)
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        #expect(cache.data(hash: "../../x", name: "doc.content") == nil)
        #expect(throws: CloudError.self) { try cache.store(Data("x".utf8), hash: "../../x", name: "doc.content") }
    }
}
