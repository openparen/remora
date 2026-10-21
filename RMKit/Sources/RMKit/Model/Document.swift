import Foundation

/// An opened document: its files, its content and its pages in order.
public struct Document: Sendable {
    public let id: String
    public let files: [Entry]
    public let content: DocumentContent
    public let pages: [PageRef]

    public static func load(_ item: LibraryItem, blobs: BlobStore) async throws -> Document {
        let files = try await blobs.entries(hash: item.hash, id: item.id)
        guard let contentFile = files.first(where: { $0.id == "\(item.id).content" }) else {
            throw CloudError.malformed("\(item.id) has no .content")
        }
        let content = try JSONDecoder().decode(DocumentContent.self, from: try await blobs.data(hash: contentFile.hash, name: contentFile.id))
        var pagedata: [String] = []
        if let file = files.first(where: { $0.id == "\(item.id).pagedata" }) {
            pagedata = String(decoding: try await blobs.data(hash: file.hash, name: file.id), as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
        let prefix = "\(item.id)/"
        let rmPageIDs = files.map(\.id)
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".rm") }
            .map { String($0.dropFirst(prefix.count).dropLast(3)) }
        let pages = PageMap.pages(content: content, rmPageIDs: rmPageIDs, pagedata: pagedata)
        return Document(id: item.id, files: files, content: content, pages: pages)
    }

    /// The page's ink file; nil for a page nobody drew on.
    public func inkFile(_ page: PageRef) -> Entry? {
        files.first { $0.id == "\(id)/\(page.id).rm" }
    }

    /// The page's strokes, or nil for a blank page.
    public func ink(_ page: PageRef, blobs: BlobStore) async throws -> NormalizedPage? {
        guard let file = inkFile(page) else { return nil }
        let rm = try parseRM(try await blobs.data(hash: file.hash, name: file.id))
        return normalize(rm, orientation: content.orientation)
    }
}
