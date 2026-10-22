import Foundation

/// Where an EPUB's chapter link goes. The tablet's PDF of an EPUB keeps a link
/// to a chapter as its bare file name (`story_0002.xhtml`), with no page, and
/// starts every chapter on a new page under its title. So a link goes to the
/// first later page that opens with the link's own text.
public enum ChapterLinks {
    /// What's compared: letters only, so line breaks, hyphenation and punctuation don't matter.
    public static func letters<S: StringProtocol>(_ text: S) -> String {
        String(text.lowercased().filter(\.isLetter))
    }

    /// The index of the page the chapter titled `title` starts on, searching the
    /// pages after `after`. `pageStarts` is each page's opening text, as `letters`.
    // ponytail: matched by title; a chapter whose heading differs from its table-of-contents entry isn't found
    public static func chapterStart(title: String, pageStarts: [String], after: Int) -> Int? {
        let wanted = letters(title)
        guard wanted.count >= 3, after + 1 < pageStarts.count else { return nil }
        // text extraction can drop a ligature (fi, ffi) from the link, so the page may have a few letters more
        let window = wanted.count + max(4, wanted.count / 5)
        return (after + 1..<pageStarts.count).first { index in
            let start = pageStarts[index]
            return start.first == wanted.first && isSubsequence(wanted, of: start.prefix(window))
        }
    }

    private static func isSubsequence(_ needle: String, of haystack: Substring) -> Bool {
        var rest = needle[...]
        for character in haystack where rest.first == character { rest = rest.dropFirst() }
        return rest.isEmpty
    }
}
