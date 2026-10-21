/// A pen as `.rm` files store it. Firmware renumbered the pens once, so two
/// codes can name the same pen.
public enum Pen: String, Sendable, CaseIterable {
    case brush, pencil, ballpoint, marker, fineliner, highlighter, eraser
    case mechanicalPencil, eraseArea, calligraphy, shader

    public init?(code: Int) {
        switch code {
        case 0, 12: self = .brush
        case 1, 14: self = .pencil
        case 2, 15: self = .ballpoint
        case 3, 16: self = .marker
        case 4, 17: self = .fineliner
        case 5, 18: self = .highlighter
        case 6: self = .eraser
        case 7, 13: self = .mechanicalPencil
        case 8: self = .eraseArea
        case 21: self = .calligraphy
        case 23: self = .shader
        default: return nil
        }
    }
}

/// A colour code as `.rm` files store it. `highlight` means "use the stroke's
/// own `colorRgba`".
public enum InkColor: String, Sendable, CaseIterable {
    case black, gray, white, yellow, green, pink, blue, red, grayOverlap, highlight, cyan, magenta

    public init?(code: Int) {
        switch code {
        case 0: self = .black
        case 1: self = .gray
        case 2: self = .white
        case 3, 13: self = .yellow
        case 4, 10: self = .green
        case 5: self = .pink
        case 6: self = .blue
        case 7: self = .red
        case 8: self = .grayOverlap
        case 9: self = .highlight
        case 11: self = .cyan
        case 12: self = .magenta
        default: return nil
        }
    }
}
