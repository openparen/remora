import CoreGraphics
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

    /// The page drawn at `scale` with its template under the ink. A blank page
    /// (no ink file) is just its template. `template` is nil when the page names
    /// one Remora doesn't draw; the caller shows `page.template` instead.
    // ponytail: a blank page has no size of its own and is drawn at the rm2 size; Paper Pro pages share its 3:4 shape
    public func render(_ page: PageRef, scale: Double, blobs: BlobStore) async throws -> (image: CGImage, template: PageTemplate?, drops: PageDrops) {
        let ink = try await ink(page, blobs: blobs)
            ?? NormalizedPage(strokes: [], drops: PageDrops(), geometry: PageGeometry(portrait: nil, orientation: content.orientation))
        let template = PageTemplate(name: page.template, page: ink.geometry)
        let image = try FlatRenderer.image(ink, scale: scale, template: template ?? .blank)
        return (image, template, ink.drops)
    }
}
