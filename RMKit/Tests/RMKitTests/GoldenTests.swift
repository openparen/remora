import Foundation
import Testing
@testable import RMKit

@Suite struct GoldenTests {
    @Test func fixturesArePresent() {
        #expect(Fixtures.rmsceneNames().count == 13)
    }

    /// rm2agent ignores text anchors, so its goldens are compared with ours
    /// unanchored; the anchors are checked against `Lines_v2` below.
    @Test(arguments: Fixtures.rmsceneNames())
    func matchesRm2agent(name: String) throws {
        var page = try parseRM(try Fixtures.data(name, "rm"))
        for i in page.strokes.indices { page.strokes[i].anchorOffset = (0, 0) }
        let normalized = normalize(page, orientation: .portrait)
        #expect(!normalized.drops.isLossy)
        try expectSVG(normalized, equals: name)
    }

    /// The same drawing before and after firmware moved it into a group
    /// anchored to the text's top: anchored, it lands exactly where it was.
    @Test func anAnchoredGroupLandsWhereTheUnanchoredOriginalWas() throws {
        let page = try parseRM(try Fixtures.data("Lines_v2_updated", "rm"))
        #expect(page.strokes.contains { $0.anchorOffset != (0, 0) })
        try expectSVG(normalize(page, orientation: .portrait), equals: "Lines_v2")
    }

    private func expectSVG(_ page: NormalizedPage, equals name: String) throws {
        let ours = try SVG.render(page).split(separator: "\n", omittingEmptySubsequences: false)
        let theirs = String(decoding: try Fixtures.data(name, "svg"), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
        #expect(ours.count == theirs.count, "line count \(ours.count) vs rm2agent \(theirs.count)")
        if let line = zip(ours, theirs).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            Issue.record("line \(line + 1) differs\n ours:     \(ours[line].prefix(200))\n rm2agent: \(theirs[line].prefix(200))")
        }
    }
}
