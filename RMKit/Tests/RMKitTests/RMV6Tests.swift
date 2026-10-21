import Foundation
import Testing
@testable import RMKit

@Suite struct RMV6Tests {
    @Test func readsEveryStrokeOfASample() throws {
        let page = try parseRM(try Fixtures.data("Color_and_tool_v3.14.4", "rm"))
        #expect(page.version == 6)
        #expect(page.unreadableBlocks == 0)
        #expect(page.strokes.count == 25)
        #expect(Set(page.strokes.map(\.pen)) == [.ballpoint, .shader])
        #expect(page.strokes.contains { $0.colorRgba != nil }) // the shader carries its own colour
        #expect(page.strokes.allSatisfy { $0.id != nil && !$0.points.isEmpty })
    }

    @Test func aTextOnlyPageHasNoStrokes() throws {
        let page = try parseRM(try Fixtures.data("Normal_AB", "rm"))
        #expect(page.strokes.isEmpty)
        #expect(page.unreadableBlocks == 0)
    }

    @Test func aTruncatedFileKeepsWhatParsedAndSaysSo() throws {
        let data = try Fixtures.data("Color_and_tool_v3.14.4", "rm")
        let page = try parseRM(data.prefix(data.count - 10))
        #expect(page.unreadableBlocks > 0)
    }

    @Test func refusesSomethingElse() {
        #expect(throws: RMParseError.notAnRMFile) { try parseRM(Data("hello".utf8)) }
    }
}
