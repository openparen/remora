import Foundation

/// The flat v3/v5 format: layers of strokes of six-float points.
/// Ported from rmapi-js `rm5.js` (MIT).
enum RMV5 {
    static func parse(_ data: Data, version: Int) throws -> RMPage {
        let r = ByteReader(data, offset: rmHeaderLength)
        var strokes: [RawStroke] = []
        for _ in 0..<(try count(r)) {
            for _ in 0..<(try count(r)) {
                let penCode = Int(try r.i32())
                guard let pen = Pen(code: penCode) else { throw RMParseError.unknownPen(penCode) }
                let colorCode = Int(try r.i32())
                guard let color = InkColor(code: colorCode) else { throw RMParseError.unknownColor(colorCode) }
                _ = try r.i32() // padding
                let baseSize = try Double(r.f32())
                if version == 5 { _ = try r.i32() } // unknown
                let pointCount = try count(r)
                guard pointCount <= r.remaining / 24 else { throw RMParseError.truncated }
                var points: [RawPoint] = []
                points.reserveCapacity(pointCount)
                for _ in 0..<pointCount {
                    let x = try Double(r.f32()), y = try Double(r.f32())
                    let speed = try Double(r.f32()), direction = try Double(r.f32())
                    let width = try Double(r.f32()), pressure = try Double(r.f32())
                    points.append(RawPoint(x: x, y: y, speed: speed, direction: direction, width: width, pressure: pressure))
                }
                strokes.append(RawStroke(
                    pen: pen, color: color, colorRgba: nil, thicknessScale: baseSize,
                    points: points, id: nil, hidden: false))
            }
        }
        return RMPage(version: version, strokes: strokes, paperSize: nil, unreadableBlocks: 0)
    }

    private static func count(_ r: ByteReader) throws -> Int {
        let value = try r.i32()
        guard value >= 0 else { throw RMParseError.truncated }
        return Int(value)
    }
}
