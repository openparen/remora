import Testing
@testable import RMKit

@Suite struct CodesTests {
    @Test func bothNumberingsNameTheSamePen() {
        #expect(Pen(code: 0) == .brush)
        #expect(Pen(code: 12) == .brush)
        #expect(Pen(code: 21) == .calligraphy)
        #expect(Pen(code: 9) == nil)
    }

    @Test func colourCodes() {
        #expect(InkColor(code: 9) == .highlight)
        #expect(InkColor(code: 13) == .yellow)
        #expect(InkColor(code: 14) == nil)
    }
}
