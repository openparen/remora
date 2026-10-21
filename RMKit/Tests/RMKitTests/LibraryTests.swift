import Foundation
import Testing
@testable import RMKit

@Suite struct LibraryTests {
    /// An in-memory account: a root with one folder and one notebook inside it.
    static func account() -> [String: Data] {
        func json(_ s: String) -> Data { Data(s.utf8) }
        return [
            fakeHash(1): json("4\n0:.:2:0\n\(fakeHash(10)):0:folder:2:0\n\(fakeHash(20)):0:note:2:0\n"),
            fakeHash(10): json("3\n\(fakeHash(11)):0:folder.metadata:0:0\n\(fakeHash(12)):0:folder.content:0:0\n"),
            fakeHash(11): json(#"{"visibleName":"Work","parent":"","type":"CollectionType","pinned":false}"#),
            fakeHash(12): json(#"{"tags":[]}"#),
            fakeHash(20): json("3\n\(fakeHash(21)):0:note.metadata:0:0\n\(fakeHash(22)):0:note.content:0:0\n"),
            fakeHash(21): json(#"{"visibleName":"Ideas","parent":"folder","type":"DocumentType","pinned":true,"lastModified":"1700000000000"}"#),
            fakeHash(22): json(#"{"fileType":"notebook","pageCount":3,"tags":["t"]}"#),
        ]
    }

    static func store(_ blobs: [String: Data], fetched: Locked<[String]> = Locked([])) -> BlobStore {
        BlobStore(cache: BlobCache(directory: temporaryDirectory())) { hash, name in
            fetched.update { $0.append(name) }
            guard let data = blobs[hash] else { throw CloudError.http(status: 404, body: name) }
            return data
        }
    }

    @Test func buildsTheTree() async throws {
        let root = RootHash(hash: fakeHash(1), generation: 1, schemaVersion: 4)
        let library = try await Library.build(root: root, blobs: Self.store(Self.account()))
        #expect(library.failures.isEmpty)
        #expect(library.items["folder"]?.kind == .folder)
        let note = try #require(library.items["note"])
        #expect(note.kind == .notebook)
        #expect(note.pinned)
        #expect(note.pageCount == 3)
        #expect(note.tags == ["t"])
        #expect(note.lastModified == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(library.path(of: "note") == "Work/Ideas")
        #expect(library.children(of: "").map(\.id) == ["folder"])
    }

    @Test func reusesUnchangedItemsAndRecordsFailures() async throws {
        var blobs = Self.account()
        let first = try await Library.build(
            root: RootHash(hash: fakeHash(1), generation: 1, schemaVersion: 4), blobs: Self.store(blobs))
        // a new root where "note" is unchanged and a third item is unreadable
        blobs[fakeHash(2)] = Data("4\n0:.:3:0\n\(fakeHash(10)):0:folder:2:0\n\(fakeHash(20)):0:note:2:0\n\(fakeHash(30)):0:broken:2:0\n".utf8)
        let fetched = Locked<[String]>([])
        let second = try await Library.build(
            root: RootHash(hash: fakeHash(2), generation: 2, schemaVersion: 4),
            previous: first, blobs: Self.store(blobs, fetched: fetched))
        #expect(fetched.value == ["root.docSchema", "broken.docSchema"])
        #expect(second.items["note"] == first.items["note"])
        #expect(second.failures.keys.sorted() == ["broken"])
    }

    @Test func aFailedContentFetchIsAFailureNotANotebook() async throws {
        var blobs = Self.account()
        blobs.removeValue(forKey: fakeHash(22)) // note.content 404s
        let root = RootHash(hash: fakeHash(1), generation: 1, schemaVersion: 4)
        let library = try await Library.build(root: root, blobs: Self.store(blobs))
        #expect(library.failures.keys.sorted() == ["note"])
        #expect(library.items["note"] == nil)
    }

    @Test func anUnparseableContentIsAFailureNotANotebook() async throws {
        var blobs = Self.account()
        blobs[fakeHash(22)] = Data("not json".utf8) // note.content is not an object at all
        let root = RootHash(hash: fakeHash(1), generation: 1, schemaVersion: 4)
        let library = try await Library.build(root: root, blobs: Self.store(blobs))
        #expect(library.failures.keys.sorted() == ["note"])
        #expect(library.items["note"] == nil)
    }
}
