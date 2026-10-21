import Foundation

/// From `.content`: orientation is per document, never per page.
public enum Orientation: String, Sendable {
    case portrait, landscape
}

/// `<id>.metadata`
public struct ItemMetadata: Decodable, Sendable {
    public var visibleName: String
    public var parent: String
    /// DocumentType, CollectionType or TemplateType
    public var type: String
    public var pinned: Bool
    /// Milliseconds since 1970, as a string.
    public var lastModified: String?
}

/// `<id>.content`, read leniently: a field of an unexpected shape is dropped,
/// not allowed to cost the whole document.
public struct DocumentContent: Decodable, Sendable {
    public var fileType: String?
    public var orientation: Orientation
    public var pageCount: Int?
    /// The legacy page list: page ids in order. `null` on a never-opened document.
    public var pages: [String]?
    /// Legacy: the zero-based source PDF page of each page, -1 for an inserted page.
    public var redirectionPageMap: [Int]?
    /// The newer page list, ordered by `idx`.
    public var cPages: [CPage]
    public var tags: [String]

    private enum Keys: String, CodingKey {
        case fileType, orientation, pageCount, pages, redirectionPageMap, cPages, tags
    }

    private struct CPagesBox: Decodable { var pages: [CPage] }

    /// A tag is a string in legacy content and `{name, timestamp}` in newer content.
    private struct Tag: Decodable {
        var name: String
        private enum Keys: String, CodingKey { case name }
        init(from decoder: Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                self.name = name
            } else {
                name = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .name)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        fileType = try? c.decodeIfPresent(String.self, forKey: .fileType)
        orientation = (try? c.decodeIfPresent(String.self, forKey: .orientation)) == "landscape" ? .landscape : .portrait
        pageCount = try? c.decodeIfPresent(Int.self, forKey: .pageCount)
        pages = try? c.decodeIfPresent([String].self, forKey: .pages)
        redirectionPageMap = try? c.decodeIfPresent([Int].self, forKey: .redirectionPageMap)
        cPages = (try? c.decodeIfPresent(CPagesBox.self, forKey: .cPages))?.pages ?? []
        tags = ((try? c.decodeIfPresent([Tag].self, forKey: .tags)) ?? []).map(\.name)
    }

    public init(orientation: Orientation = .portrait, pages: [String]? = nil, redirectionPageMap: [Int]? = nil, cPages: [CPage] = []) {
        self.orientation = orientation
        self.pages = pages
        self.redirectionPageMap = redirectionPageMap
        self.cPages = cPages
        tags = []
    }
}

/// One entry of `cPages.pages`. Each field is `{timestamp, value}` on disk.
public struct CPage: Decodable, Sendable {
    public var id: String?
    public var idx: String?
    public var template: String?
    /// The zero-based source PDF page.
    public var redir: Int?
    public var deleted: Bool

    private enum Keys: String, CodingKey { case id, idx, template, redir, deleted }
    private struct Wrapped<T: Decodable>: Decodable { var value: T }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try? c.decode(String.self, forKey: .id)
        idx = (try? c.decode(Wrapped<String>.self, forKey: .idx))?.value
        template = (try? c.decode(Wrapped<String>.self, forKey: .template))?.value
        redir = (try? c.decode(Wrapped<Int>.self, forKey: .redir))?.value
        let deletedNumber = (try? c.decode(Wrapped<Int>.self, forKey: .deleted))?.value
        let deletedFlag = (try? c.decode(Wrapped<Bool>.self, forKey: .deleted))?.value
        deleted = (deletedNumber ?? 0) != 0 || deletedFlag == true
    }

    public init(id: String?, idx: String?, template: String? = nil, redir: Int? = nil, deleted: Bool = false) {
        self.id = id
        self.idx = idx
        self.template = template
        self.redir = redir
        self.deleted = deleted
    }
}
