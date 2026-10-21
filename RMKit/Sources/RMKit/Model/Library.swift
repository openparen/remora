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

    /// Read every item of `root`, reusing `previous` for items whose hash is unchanged.
    public static func build(
        root: RootHash,
        previous: Library? = nil,
        blobs: BlobStore,
        concurrency: Int = 8
    ) async throws -> Library {
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
                case .failure(let error): failures[id] = "\(error)"
                }
                next()
            }
        }
        return Library(root: root, items: items, failures: failures)
    }

    private static func item(_ entry: Entry, blobs: BlobStore) async throws -> LibraryItem {
        let files = try await blobs.entries(hash: entry.hash, id: entry.id)
        guard let metaFile = files.first(where: { $0.id.hasSuffix(".metadata") }) else {
            throw CloudError.malformed("no .metadata")
        }
        let meta = try JSONDecoder().decode(ItemMetadata.self, from: try await blobs.data(hash: metaFile.hash, name: metaFile.id))
        var content: DocumentContent?
        if let contentFile = files.first(where: { $0.id.hasSuffix(".content") }) {
            content = try? JSONDecoder().decode(DocumentContent.self, from: try await blobs.data(hash: contentFile.hash, name: contentFile.id))
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
            pageCount: content?.pageCount)
    }
}
