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
    /// A `nil` element is an unreadable page: it keeps its slot (and page number)
    /// but has no id of its own.
    public var pages: [String?]?
    /// Legacy: the zero-based source PDF page of each page, -1 for an inserted page.
    /// A `nil` element means that page has no source. Present but not an array
    /// (some broken documents) means "no source pages", one `nil` per page.
    public var redirectionPageMap: [Int?]?
    /// The newer page list, ordered by `idx`.
    public var cPages: [CPage]
    public var tags: [String]

    private enum Keys: String, CodingKey {
        case fileType, orientation, pageCount, pages, redirectionPageMap, cPages, tags
    }

    /// Decodes one element of a list, or nil, so one bad element keeps its slot.
    private struct Lenient<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(T.self) }
    }

    private struct CPagesBox: Decodable {
        var pages: [CPage]
        private enum Keys: String, CodingKey { case pages }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            pages = try c.decode([Lenient<CPage>].self, forKey: .pages).map { $0.value ?? CPage(id: nil, idx: nil) }
        }
    }

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
        let pagesLenient = (try? c.decodeIfPresent([Lenient<String>].self, forKey: .pages)) ?? nil
        pages = pagesLenient?.map(\.value)
        let redirLenient = (try? c.decodeIfPresent([Lenient<Int>].self, forKey: .redirectionPageMap)) ?? nil
        if let redirLenient {
            redirectionPageMap = redirLenient.map(\.value)
        } else if c.contains(.redirectionPageMap), (try? c.decodeNil(forKey: .redirectionPageMap)) != true {
            // present but not an array: no source pages, never identity
            redirectionPageMap = Array(repeating: nil, count: pages?.count ?? 0)
        } else {
            redirectionPageMap = nil
        }
        cPages = (try? c.decodeIfPresent(CPagesBox.self, forKey: .cPages))?.pages ?? []
        tags = ((try? c.decodeIfPresent([Tag].self, forKey: .tags)) ?? []).map(\.name)
    }

    public init(orientation: Orientation = .portrait, pages: [String?]? = nil, redirectionPageMap: [Int?]? = nil, cPages: [CPage] = []) {
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
