import CoreGraphics

extension CGImage {
    /// The image turned clockwise, as seen, by `quarterTurns` quarter turns.
    public func turned(_ quarterTurns: Int) -> CGImage? {
        let turns = (quarterTurns % 4 + 4) % 4
        guard turns != 0 else { return self }
        let (w, h) = turns % 2 == 0 ? (width, height) : (height, width)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CoreGraphics runs y up, so turning clockwise as seen is a negative angle
        context.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.draw(self, in: CGRect(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2, width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage()
    }
}
