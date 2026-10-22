import Testing
@testable import RMKit

@Suite struct ChapterLinksTests {
    // page openings as the tablet's PDF of an EPUB has them: a table of contents, then chapters
    let pages = [
        "Contents Örökké tehetségesek Lack János: Hétfőember A gólya",
        "Örökké tehetségesek\n2020. december 19.\nMert az is kérdés",
        "a story going on, a gólya is mentioned in passing",
        "Lackfi János: Hétfőember (válogatott\nhatáraim)\n2021. január",
        "A gólya\n2021. február",
    ].map { ChapterLinks.letters($0.prefix(300)) }

    @Test func aLinkGoesToTheLaterPageThatOpensWithItsTitle() {
        #expect(ChapterLinks.chapterStart(title: "Örökké tehetségesek", pageStarts: pages, after: 0) == 1)
        // a title mentioned mid-page isn't a chapter start
        #expect(ChapterLinks.chapterStart(title: "A gólya", pageStarts: pages, after: 0) == 4)
    }

    @Test func aLigatureTheLinkTextLostStillMatches() {
        // "Lackfi": the fi ligature extracts as nothing from the link
        #expect(ChapterLinks.chapterStart(title: "Lack János: Hétfőember (válogatott határaim)", pageStarts: pages, after: 0) == 3)
    }

    @Test func numberedChaptersStayApart() {
        let book = ["Contents Chapter 1 Chapter 2", "Chapter 1 It begins", "Chapter 2 It goes on"].map { ChapterLinks.letters($0) }
        #expect(ChapterLinks.chapterStart(title: "Chapter 2", pageStarts: book, after: 0) == 2)
    }

    @Test func onlyLigatureLettersMaySlip() {
        // "Ann" must not match a page that opens "And then"
        let book = ["Contents", "And then she left", "Ann"].map { ChapterLinks.letters($0) }
        #expect(ChapterLinks.chapterStart(title: "Ann", pageStarts: book, after: 0) == 2)
    }

    @Test func noTitleOrNoMatchGoesNowhere() {
        #expect(ChapterLinks.chapterStart(title: "1", pageStarts: pages, after: 0) == nil)
        #expect(ChapterLinks.chapterStart(title: "Nincs ilyen fejezet", pageStarts: pages, after: 0) == nil)
        #expect(ChapterLinks.chapterStart(title: "Örökké tehetségesek", pageStarts: pages, after: 4) == nil)
    }
}
