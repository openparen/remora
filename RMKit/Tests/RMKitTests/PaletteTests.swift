import Testing
@testable import RMKit

@Suite struct PaletteTests {
    @Test func packedColourWinsAndIsCappedByThePen() {
        let style = Palette.style(pen: .highlighter, color: .highlight, rgba: 0xff_ff_00_00)
        #expect(style.color == "#ff0000")
        #expect(style.opacity == 0.35)
    }

    @Test func zeroIsNoColourAndErasersErase() {
        #expect(Palette.style(pen: .ballpoint, color: .blue, rgba: 0).color == "#0062cc")
        #expect(Palette.style(pen: .eraser, color: .black, rgba: nil).erase)
    }
}
