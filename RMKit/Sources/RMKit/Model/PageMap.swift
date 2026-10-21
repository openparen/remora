import Foundation

/// A page of a document: its stable id, the number the tablet shows it at,
/// and the source PDF page under it, if any.
public struct PageRef: Sendable, Equatable {
    public let id: String
    /// One-based, derived from the order. Links key on `id`, never on this.
    public let number: Int
    /// One-based source PDF page; nil for notebook pages and pages inserted into a PDF.
    public let sourcePage: Int?
    public let template: String?
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
            // idx is compared byte-wise, as the device does; missing idx sorts first
            // ponytail: rm2agent refuses to number a document with a missing idx; we fall back to array order
            let ordered = live.sorted { a, b in
                let ai = Array((a.element.idx ?? "").utf8), bi = Array((b.element.idx ?? "").utf8)
                return ai == bi ? a.offset < b.offset : ai.lexicographicallyPrecedes(bi)
            }
            return ordered.enumerated().compactMap { offset, page in
                guard let id = page.element.id else { return nil } // keeps its number, has no entry
                let number = offset + 1
                let source = page.element.redir.flatMap { $0 >= 0 ? $0 + 1 : nil }
                return PageRef(id: id, number: number, sourcePage: source, template: template(page.element.template, number))
            }
        }

        if let pages = content.pages, !pages.isEmpty {
            let map = content.redirectionPageMap ?? []
            return pages.enumerated().map { offset, id in
                let number = offset + 1
                // no map means each page sits on the source page of the same number
                let source: Int? = map.isEmpty ? number : map.indices.contains(offset) && map[offset] >= 0 ? map[offset] + 1 : nil
                return PageRef(id: id, number: number, sourcePage: source, template: template(nil, number))
            }
        }

        return rmPageIDs.enumerated().map { offset, id in
            PageRef(id: id, number: offset + 1, sourcePage: nil, template: template(nil, offset + 1))
        }
    }
}
