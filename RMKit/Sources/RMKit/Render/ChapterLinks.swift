import Foundation

/// Where an EPUB's chapter link goes. The tablet's PDF of an EPUB keeps a link
/// to a chapter as its bare file name (`story_0002.xhtml`), with no page, and
/// starts every chapter on a new page under its title. So a link goes to the
/// first later page that opens with the link's own text.
public enum ChapterLinks {
    /// What's compared: letters and digits only, so line breaks, hyphenation and punctuation don't matter.
    public static func letters<S: StringProtocol>(_ text: S) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The index of the page the chapter titled `title` starts on, searching the
    /// pages after `after`. `pageStarts` is each page's opening text, as `letters`.
    // ponytail: matched by title; a chapter whose heading differs from its table-of-contents entry isn't found
    public static func chapterStart(title: String, pageStarts: [String], after: Int) -> Int? {
        let wanted = letters(title)
        guard wanted.count >= 3, after >= -1, after + 1 < pageStarts.count else { return nil }
        return (after + 1..<pageStarts.count).first { opens(pageStarts[$0], with: wanted) }
    }

    /// True when `page` starts with `title`. Text extraction can drop a ligature (ff, fi, fl, ffi, ffl)
    /// from the link, so the page may have an f, i or l more here and there, and nothing else.
    private static func opens(_ page: String, with title: String) -> Bool {
        var rest = title[...]
        for character in page {
            if rest.isEmpty { return true }
            if character == rest.first {
                rest = rest.dropFirst()
            } else if !"fil".contains(character) {
                return false
            }
        }
        return rest.isEmpty
    }
}
