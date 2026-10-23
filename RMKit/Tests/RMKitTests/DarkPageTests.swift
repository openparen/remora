import CoreGraphics
import Foundation
import Testing
@testable import RMKit

@Suite struct DarkPageTests {
    @Test func paperGoesDarkAndInkGoesLight() {
        let paper = DarkPage.darken(SIMD3(1, 1, 1))
        let ink = DarkPage.darken(SIMD3(0, 0, 0))
        #expect(abs(paper.x - 0.118) < 0.01 && abs(paper.x - paper.z) < 0.001)
        #expect(abs(ink.x - 0.878) < 0.01 && abs(ink.x - ink.z) < 0.001)
    }

    @Test func colourKeepsItsHue() {
        // reMarkable red and blue ink stay red and blue, only lighter
        let red = DarkPage.darken(SIMD3(0xd0, 0x20, 0x20) / 255)
        let blue = DarkPage.darken(SIMD3(0x00, 0x62, 0xcc) / 255)
        #expect(red.x > red.y + 0.2 && red.x > red.z + 0.2)
        #expect(blue.z > blue.x + 0.2 && blue.z > blue.y)
        // mid-tone ink keeps about its lightness, which is still well clear of the dark paper
        #expect(OKLab(srgb: red).l > DarkPage.paper + 0.25 && OKLab(srgb: blue).l > DarkPage.paper + 0.25)
    }

    @Test func everyColourLandsInRange() {
        for r in stride(from: 0.0, through: 1, by: 0.25) {
            for g in stride(from: 0.0, through: 1, by: 0.25) {
                for b in stride(from: 0.0, through: 1, by: 0.25) {
                    let c = DarkPage.darken(SIMD3(r, g, b))
                    #expect(c.min() >= 0 && c.max() <= 1)
                    let l = OKLab(srgb: c).l
                    #expect(l >= DarkPage.paper - 0.01 && l <= DarkPage.ink + 0.01)
                }
            }
        }
    }

    @Test func darkensAnImage() throws {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        let dark = try #require(DarkPage.darken(image))
        let bytes = try #require(dark.dataProvider?.data) as Data
        #expect(dark.width == 4)
        #expect(abs(Int(bytes[0]) - 30) <= 3)
    }
}
