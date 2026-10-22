import Foundation

/// A page of a document: its stable id, the number the tablet shows it at,
/// and the source PDF page under it, if any.
public struct PageRef: Sendable, Equatable {
    public let id: String
    /// One-based, derived from the order. Links key on `id`, never on this.
    public let number: Int
    /// One-based source PDF page. nil for a page inserted into a PDF. A legacy
    /// document with no redirection map gets identity, so a notebook's caller
    /// ignores this field.
    public let sourcePage: Int?
    public let template: String?
    /// The page of a fresh upload the tablet hasn't opened yet: its id isn't the
    /// tablet's, so a link to it would break once the tablet opens the document.
    public var provisional = false
}

/// Page order from `.content`, ported from rm2agent `page-map.ts`. The schema
/// is chosen by shape, not `formatVersion`: `cPages` if it has pages, else the
/// legacy `pages` list, else the order of the `.rm` files.
public enum PageMap {
    public static func pages(content: DocumentContent, rmPageIDs: [String], pagedata: [String] = []) -> [PageRef] {
        func template(_ declared: String?, _ number: Int) -> String? {
            if let declared, !declared.isEmpty { return declared }
            let line = pagedata.indices.contains(number - 1) ? pagedata[number - 1] : ""
            return line.isEmpty ? nil : line
        }

        if !content.cPages.isEmpty {
            // deleted pages stay in the list; numbering them would shift every later page
            let live = content.cPages.filter { !$0.deleted }.enumerated()
            // idx is compared byte-wise, as the device does
            // ponytail: rm2agent refuses to number a document with a missing idx; we keep such a page right after the page before it in the array
            var previous = ""
            let keyed = live.map { offset, page -> (offset: Int, page: CPage, key: [UInt8]) in
                let effective = page.idx ?? previous
                previous = effective
                return (offset, page, Array(effective.utf8))
            }
            let ordered = keyed.sorted { a, b in
                a.key == b.key ? a.offset < b.offset : a.key.lexicographicallyPrecedes(b.key)
            }
            return ordered.enumerated().compactMap { offset, entry in
                guard let id = entry.page.id else { return nil } // keeps its number, has no entry
                let number = offset + 1
                let source = entry.page.redir.flatMap { $0 >= 0 ? $0 + 1 : nil }
                return PageRef(id: id, number: number, sourcePage: source, template: template(entry.page.template, number))
            }
        }

        if let pages = content.pages, !pages.isEmpty {
            let map = content.redirectionPageMap ?? []
            return pages.enumerated().compactMap { offset, id in
                let number = offset + 1
                // no map means each page sits on the source page of the same number
                let source: Int? = map.isEmpty ? number : (map.indices.contains(offset) ? map[offset] : nil).flatMap { $0 >= 0 ? $0 + 1 : nil }
                guard let id else { return nil } // keeps its number, has no entry
                return PageRef(id: id, number: number, sourcePage: source, template: template(nil, number))
            }
        }

        return rmPageIDs.enumerated().map { offset, id in
            PageRef(id: id, number: offset + 1, sourcePage: nil, template: template(nil, offset + 1))
        }
    }
}
