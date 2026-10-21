import Foundation
import Testing
@testable import RMKit

@Suite struct GoldenTests {
    @Test func fixturesArePresent() {
        #expect(Fixtures.rmsceneNames().count == 13)
    }

    @Test(arguments: Fixtures.rmsceneNames())
    func matchesRm2agent(name: String) throws {
        let page = try parseRM(try Fixtures.data(name, "rm"))
        let normalized = normalize(page, orientation: .portrait)
        #expect(!normalized.drops.isLossy)
        let ours = try SVG.render(normalized).split(separator: "\n", omittingEmptySubsequences: false)
        let theirs = String(decoding: try Fixtures.data(name, "svg"), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
        #expect(ours.count == theirs.count, "line count \(ours.count) vs rm2agent \(theirs.count)")
        if let line = zip(ours, theirs).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            Issue.record("line \(line + 1) differs\n ours:     \(ours[line].prefix(200))\n rm2agent: \(theirs[line].prefix(200))")
        }
    }
}
