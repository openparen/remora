import Foundation
import Testing
@testable import RMKit

@Suite struct RMV5Tests {
    @Test func readsLayersOfStrokes() throws {
        let page = try RMV5.parse(Fixtures.v5(), version: 5)
        #expect(page.version == 5)
        #expect(page.strokes.count == 1)
        #expect(page.strokes[0].pen == .ballpoint)
        #expect(page.strokes[0].color == .black)
        #expect(page.strokes[0].points.map(\.x) == [10, 30])
        #expect(page.strokes[0].points[0].width == 2.5)
    }
}
