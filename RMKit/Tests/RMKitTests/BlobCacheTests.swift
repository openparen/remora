import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
        let store = BlobStore(cache: BlobCache(directory: temporaryDirectory()), verifyHashes: false) { _, _ in
            fetches.update { $0 += 1 }
            return Data("x".utf8)
        }
        defer { try? FileManager.default.removeItem(at: store.cache.directory) }
        _ = try await store.data(hash: fakeHash(1), name: "a.content")
        _ = try await store.data(hash: fakeHash(1), name: "a.content")
        #expect(fetches.value == 1)
    }

    @Test func onlyEverBuildsPathsFromValidHashes() throws {
        // the cache sits two levels inside our own disposable root, so the real
        // `keep/<prefix>/<hash>` escape for this hash lands back inside that root,
        // never in the shared system temp directory
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = BlobCache(directory: root.appending(path: "a/cache"), limit: 10)
        let hash = "../../x"
        let escape = cache.directory.appending(path: "keep").appending(path: String(hash.prefix(2))).appending(path: hash).standardized
        try FileManager.default.createDirectory(at: escape.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("leaked".utf8).write(to: escape)
        // the literal, unresolved `keep/../../../x` the code walks must exist too: ".." needs a real directory to climb out of
        try FileManager.default.createDirectory(at: cache.directory.appending(path: "keep"), withIntermediateDirectories: true)
        #expect(cache.data(hash: hash, name: "doc.content") == nil)
        #expect(throws: CloudError.self) { try cache.store(Data("x".utf8), hash: hash, name: "doc.content") }
    }

    @Test func concurrentRequestsForOneBlobShareAFetch() async throws {
        let fetches = Locked(0)
        let store = BlobStore(cache: BlobCache(directory: temporaryDirectory()), verifyHashes: false) { _, _ in
            fetches.update { $0 += 1 }
            try await Task.sleep(for: .milliseconds(50))
            return Data("x".utf8)
        }
        defer { try? FileManager.default.removeItem(at: store.cache.directory) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { _ = try await store.data(hash: fakeHash(1), name: "a.rm") } }
            try await group.waitForAll()
        }
        #expect(fetches.value == 1)
    }

    @Test func atMostTheLimitOfFetchesRunAtOnce() async throws {
        let running = Locked(0), peak = Locked(0)
        let store = BlobStore(cache: BlobCache(directory: temporaryDirectory()), maxConcurrentFetches: 2, verifyHashes: false) { _, _ in
            let now = running.update { $0 += 1; return $0 }
            peak.update { $0 = max($0, now) }
            try await Task.sleep(for: .milliseconds(30))
            running.update { $0 -= 1 }
            return Data("x".utf8)
        }
        defer { try? FileManager.default.removeItem(at: store.cache.directory) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 1...6 { group.addTask { _ = try await store.data(hash: fakeHash(n), name: "p\(n).rm") } }
            try await group.waitForAll()
        }
        #expect(peak.value == 2)
    }

    @Test func bytesThatDoNotMatchTheirHashAreRefusedAndNotCached() async throws {
        let store = BlobStore(cache: BlobCache(directory: temporaryDirectory())) { _, _ in Data("<html>login</html>".utf8) }
        defer { try? FileManager.default.removeItem(at: store.cache.directory) }
        await #expect(throws: CloudError.self) { try await store.data(hash: fakeHash(1), name: "a.content") }
        #expect(store.cache.data(hash: fakeHash(1), name: "a.content") == nil)
        // sha256("hello")
        let hello = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        let good = BlobStore(cache: BlobCache(directory: temporaryDirectory())) { _, _ in Data("hello".utf8) }
        defer { try? FileManager.default.removeItem(at: good.cache.directory) }
        #expect(try await good.data(hash: hello, name: "a.content") == Data("hello".utf8))
    }

    @Test func aFailedFetchIsTriedAgain() async throws {
        let calls = Locked(0)
        let store = BlobStore(cache: BlobCache(directory: temporaryDirectory()), verifyHashes: false) { _, _ in
            let n = calls.update { $0 += 1; return $0 }
            if n == 1 { throw URLError(.timedOut) }
            return Data("x".utf8)
        }
        defer { try? FileManager.default.removeItem(at: store.cache.directory) }
        await #expect(throws: URLError.self) { try await store.data(hash: fakeHash(1), name: "a.rm") }
        #expect(try await store.data(hash: fakeHash(1), name: "a.rm") == Data("x".utf8))
        #expect(calls.value == 2)
    }

    @Test func anEntryListThatDoesNotParseIsNotCached() async throws {
        let store = BlobStore(cache: BlobCache(directory: temporaryDirectory())) { _, _ in Data("<html>login</html>".utf8) }
        defer { try? FileManager.default.removeItem(at: store.cache.directory) }
        await #expect(throws: CloudError.self) { try await store.entries(hash: fakeHash(1), id: "root") }
        #expect(store.cache.data(hash: fakeHash(1), name: "root.docSchema") == nil)
    }
}
