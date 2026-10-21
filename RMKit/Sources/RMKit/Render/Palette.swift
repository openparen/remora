import Foundation

/// The paint one stroke needs.
public struct StrokeStyle: Sendable, Equatable {
    /// `#rrggbb`
    public var color: String
    /// 0...1
    public var opacity: Double
    /// Eraser strokes remove ink rather than add it.
    public var erase: Bool
    public var pen: Pen
}

/// Pen and colour codes to paint. Ported from rm2agent `palette.ts`. The
/// switches are exhaustive on purpose: a pen or colour added upstream must
/// fail the build, not paint black.
public enum Palette {
    static func shade(_ color: InkColor) -> String {
        switch color {
        case .black: "#000000"
        case .gray, .grayOverlap: "#808080"
        case .white: "#ffffff"
        case .yellow, .highlight: "#f5d800"
        case .green: "#00a000"
        case .pink: "#ff70c0"
        case .blue: "#0062cc"
        case .red: "#d02020"
        case .cyan: "#00b0c0"
        case .magenta: "#c000a0"
        }
    }

    static func maxOpacity(_ pen: Pen) -> Double {
        switch pen {
        case .highlighter: 0.35
        case .shader: 0.5
        case .brush, .pencil, .ballpoint, .marker, .fineliner, .mechanicalPencil,
             .calligraphy, .eraser, .eraseArea: 1
        }
    }

    public static func style(pen: Pen, color: InkColor, rgba: UInt32?) -> StrokeStyle {
        var hex = shade(color)
        var opacity = 1.0
        // a packed zero is an absent field, not transparent black
        if let rgba, rgba != 0 {
            hex = String(format: "#%02x%02x%02x", (rgba >> 16) & 0xff, (rgba >> 8) & 0xff, rgba & 0xff)
            let alpha = rgba >> 24
            if alpha != 0 { opacity = Double(alpha) / 255 }
        }
        return StrokeStyle(
            color: hex,
            opacity: min(opacity, maxOpacity(pen)),
            erase: pen == .eraser || pen == .eraseArea,
            pen: pen)
    }
}
