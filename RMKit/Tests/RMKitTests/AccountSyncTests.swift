import Foundation
import Testing
@testable import RMKit

@Suite struct AccountSyncTests {
    func sync(_ directory: URL, root: Locked<RootHash>, fetches: Locked<Int>) -> AccountSync {
        let blobs = LibraryTests.account()
        return AccountSync(
            account: "a", directory: directory, verifyHashes: false,
            root: { root.value },
            fetch: { hash, name in
                fetches.update { $0 += 1 }
                guard let data = blobs[hash] else { throw CloudError.http(status: 404, body: name) }
                return data
            })
    }

    @Test func refreshesThenOpensOfflineFromTheCache() async throws {
        let directory = temporaryDirectory().appending(path: "blobs")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let root = Locked(RootHash(hash: fakeHash(1), generation: 1, schemaVersion: 4))
        let fetches = Locked(0)
        let online = sync(directory, root: root, fetches: fetches)
        #expect(await online.loadCached() == nil) // nothing synced yet
        let library = try await online.refresh()
        #expect(library.items["note"]?.name == "Ideas")
        let afterSync = fetches.value
        // unchanged root: no rebuild
        _ = try await online.refresh()
        #expect(fetches.value == afterSync)
        // a new process, offline: everything comes from the cache
        let later = sync(directory, root: root, fetches: fetches)
        let cached = await later.loadCached()
        #expect(cached?.items["note"]?.name == "Ideas")
        #expect(fetches.value == afterSync)
    }

    @Test func aRefreshAtTheSameRootRetriesWhatFailed() async throws {
        let directory = temporaryDirectory().appending(path: "blobs")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let blobs = LibraryTests.account()
        let noteFails = Locked(true)
        let sync = AccountSync(
            account: "a", directory: directory, verifyHashes: false,
            root: { RootHash(hash: fakeHash(1), generation: 1, schemaVersion: 4) },
            fetch: { hash, name in
                if name == "note.docSchema", noteFails.value { throw CloudError.http(status: 404, body: name) }
                guard let data = blobs[hash] else { throw CloudError.http(status: 404, body: name) }
                return data
            })
        let first = try await sync.refresh()
        #expect(first.items["note"] == nil)
        noteFails.update { $0 = false }
        let second = try await sync.refresh()
        #expect(second.items["note"]?.name == "Ideas")
    }

    @Test func offlineShowsWhatIsCachedAndListsTheRest() async throws {
        let directory = temporaryDirectory().appending(path: "blobs")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let root = Locked(RootHash(hash: fakeHash(1), generation: 1, schemaVersion: 4))
        _ = try await sync(directory, root: root, fetches: Locked(0)).refresh()
        // lose the note's metadata from the cache, then open offline
        try FileManager.default.removeItem(at: directory.appending(path: "keep/00/\(fakeHash(21))"))
        let cached = try #require(await sync(directory, root: root, fetches: Locked(0)).loadCached())
        #expect(cached.items["folder"] != nil)
        #expect(cached.items["note"] == nil)
        #expect(cached.failures.keys.sorted() == ["note"])
    }
}
