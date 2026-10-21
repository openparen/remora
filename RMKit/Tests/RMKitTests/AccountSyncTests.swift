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
}
