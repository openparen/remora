import CoreGraphics
import Testing
@testable import RMKit

@Suite struct TurnTests {
    /// 40×20, white, with a black 5×5 square in its top-left corner as seen.
    func marked() -> CGImage {
        let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 15, width: 5, height: 5)) // y up: the top is at 20
        return context.makeImage()!
    }

    /// The red channel at (x, y), counted from the top-left as seen.
    func red(_ image: CGImage, _ x: Int, _ y: Int) -> Int {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Int(context.data!.assumingMemoryBound(to: UInt8.self)[(y * image.width + x) * 4])
    }

    @Test(arguments: [(0, 40, 20, 2, 2), (1, 20, 40, 17, 2), (2, 40, 20, 37, 17), (3, 20, 40, 2, 37), (-1, 20, 40, 2, 37), (5, 20, 40, 17, 2)])
    func theCornerMovesClockwise(turns: Int, width: Int, height: Int, x: Int, y: Int) throws {
        let image = try #require(marked().turned(turns))
        #expect(image.width == width && image.height == height)
        #expect(red(image, x, y) < 50)
    }
}
