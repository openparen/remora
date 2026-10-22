import Foundation

public struct LibraryItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case folder, notebook, pdf, epub, template }

    public let id: String
    /// The hash of the item's entry list; it changes whenever any file of the item does.
    public let hash: String
    public let name: String
    /// "" is the root, "trash" the trash.
    public let parent: String
    public let kind: Kind
    public let pinned: Bool
    public let tags: [String]
    public let lastModified: Date?
    public let pageCount: Int?
}

public struct FolderNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let children: [FolderNode]?
}

/// The account's whole tree at one root hash.
public struct Library: Sendable {
    public let root: RootHash
    public let items: [String: LibraryItem]
    /// Items that could not be read, with why. Never silently dropped.
    public let failures: [String: String]

    public func children(of parent: String) -> [LibraryItem] {
        items.values.filter { $0.parent == parent }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "Folder/Sub/Name"
    public func path(of id: String) -> String {
        var names: [String] = []
        var seen: Set<String> = []
        var current = items[id]
        while let item = current, seen.insert(item.id).inserted {
            names.append(item.name)
            current = items[item.parent]
        }
        return names.reversed().joined(separator: "/")
    }

    /// The folder tree under `parent`, sorted by name, trash left out. A folder
    /// without subfolders has `nil` children, which is what a SwiftUI outline wants.
    public func folders(under parent: String = "") -> [FolderNode] {
        var seen: Set<String> = [parent]
        func level(_ parent: String) -> [FolderNode] {
            children(of: parent).filter { $0.kind == .folder && seen.insert($0.id).inserted }.map { folder in
                let below = level(folder.id)
                return FolderNode(id: folder.id, name: folder.name, children: below.isEmpty ? nil : below)
            }
        }
        return level(parent)
    }

    /// Documents and folders whose name, tag or folder path contains `query`,
    /// name matches first, then tags, then paths. Trash and templates left out.
    public func search(_ query: String) -> [LibraryItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        func rank(_ item: LibraryItem) -> Int? {
            if item.name.localizedCaseInsensitiveContains(query) { return 0 }
            if item.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return 1 }
            if path(of: item.parent).localizedCaseInsensitiveContains(query) { return 2 }
            return nil
        }
        var hits: [(item: LibraryItem, rank: Int)] = []
        for item in items.values where item.kind != .template && !isInTrash(item.id) {
            if let rank = rank(item) { hits.append((item, rank)) }
        }
        hits.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.item.name.localizedStandardCompare(b.item.name) == .orderedAscending
        }
        return hits.map(\.item)
    }

    /// In the trash, directly or under a trashed folder.
    public func isInTrash(_ id: String) -> Bool {
        var seen: Set<String> = []
        var parent = items[id]?.parent
        while let current = parent, seen.insert(current).inserted {
            if current == "trash" { return true }
            parent = items[current]?.parent
        }
        return false
    }

    /// Read every item of `root`, reusing `previous` for items whose hash is unchanged.
    /// An item that can't be read keeps its previous version and is listed in
    /// `failures`. An error that would fail every request (auth, rate limit,
    /// network: `CloudError.failsEverything`) stops the build and is thrown, so
    /// the caller keeps its old library instead of a hollow new one.
    public static func build(
        root: RootHash,
        previous: Library? = nil,
        blobs: BlobStore,
        concurrency: Int = 8
    ) async throws -> Library {
        precondition(concurrency > 0)
        let entries = try await blobs.entries(hash: root.hash, id: "root")
        var items: [String: LibraryItem] = [:]
        var failures: [String: String] = [:]
        var pending: [Entry] = []
        for entry in entries {
            if let old = previous?.items[entry.id], old.hash == entry.hash {
                items[entry.id] = old
            } else {
                pending.append(entry)
            }
        }

        try await withThrowingTaskGroup(of: (String, Result<LibraryItem, Error>).self) { group in
            var queue = pending.makeIterator()
            func next() {
                guard let entry = queue.next() else { return }
                group.addTask {
                    do { return (entry.id, .success(try await item(entry, blobs: blobs))) }
                    catch { return (entry.id, .failure(error)) }
                }
            }
            for _ in 0..<concurrency { next() }
            while let (id, result) = try await group.next() {
                switch result {
                case .success(let item): items[id] = item
                case .failure(let error):
                    if CloudError.failsEverything(error) { throw error }
                    failures[id] = "\(error)"
                    if let old = previous?.items[id] { items[id] = old }
                }
                next()
            }
        }
        return Library(root: root, items: items, failures: failures)
    }

    private static func item(_ entry: Entry, blobs: BlobStore) async throws -> LibraryItem {
        let files = try await blobs.entries(hash: entry.hash, id: entry.id)
        guard let metaFile = files.first(where: { $0.id == "\(entry.id).metadata" }) else {
            throw CloudError.malformed("no .metadata")
        }
        let meta = try JSONDecoder().decode(ItemMetadata.self, from: try await blobs.data(hash: metaFile.hash, name: metaFile.id))
        var content: DocumentContent?
        if let contentFile = files.first(where: { $0.id == "\(entry.id).content" }) {
            let bytes = try await blobs.data(hash: contentFile.hash, name: contentFile.id)
            // DocumentContent's decoder is lenient per field; only non-object JSON throws here,
            // and that's real loss, not something to paper over as a bare notebook.
            content = try JSONDecoder().decode(DocumentContent.self, from: bytes)
        }
        let kind: LibraryItem.Kind = switch meta.type {
        case "CollectionType": .folder
        case "TemplateType": .template
        default: LibraryItem.Kind(rawValue: content?.fileType ?? "") ?? .notebook
        }
        return LibraryItem(
            id: entry.id,
            hash: entry.hash,
            name: meta.visibleName,
            parent: meta.parent,
            kind: kind,
            pinned: meta.pinned,
            tags: content?.tags ?? [],
            lastModified: meta.lastModified.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) },
            // a fresh upload's count is the server's placeholder, not the PDF's
            pageCount: content?.isUploadPlaceholder == true ? nil : content?.pageCount)
    }
}
