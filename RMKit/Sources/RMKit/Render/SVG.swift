import Foundation

/// A stretch of a stroke drawn at one width.
struct Run {
    var width: Double
    var points: [StrokePoint]
}

/// Port of rm2agent `svg.ts`, kept byte-identical so the two can be diffed.
/// Number formatting and rounding follow JavaScript's `String(n)` and `Math.round`.
public enum SVG {
    public enum Error: Swift.Error { case nonFinite(String), badColor(String) }

    private static let coordDecimals = 1
    private static let opacityDecimals = 2
    private static let minOpacity = 0.01
    private static let maxMagnitude = 9_007_199_254_740_991.0 / 10

    static func round(_ value: Double, _ decimals: Int, _ what: String) throws -> Double {
        guard value.isFinite, abs(value) <= maxMagnitude else { throw Error.nonFinite(what) }
        let scale = pow(10, Double(decimals))
        // Math.round is floor(x) + (fraction >= 0.5 ? 1 : 0), not floor(x + 0.5):
        // adding 0.5 before flooring loses precision right at the .5 boundary for
        // some doubles that floor(x) + fraction comparison gets right.
        // `+ 0` turns -0 into 0.
        let f = (value * scale).rounded(.down)
        return ((value * scale - f >= 0.5) ? f + 1 : f) / scale + 0
    }

    static func coord(_ value: Double, _ what: String) throws -> Double {
        try round(value, coordDecimals, what)
    }

    /// JavaScript's `String(n)` for the values this file produces.
    static func js(_ value: Double) -> String {
        if value == value.rounded(.towardZero), abs(value) < 1e18 { return String(Int64(value)) }
        return "\(value)"
    }

    static func runs(_ points: [StrokePoint]) throws -> [Run] {
        var runs: [Run] = []
        var previous: StrokePoint?
        for point in points {
            if let prev = previous {
                let width = try coord((prev.width + point.width) / 2, "width")
                if let last = runs.last, last.width == width {
                    runs[runs.count - 1].points.append(point)
                } else {
                    runs.append(Run(width: width, points: [prev, point]))
                }
            }
            previous = point
        }
        if runs.isEmpty, let previous {
            runs.append(Run(width: try coord(previous.width, "width"), points: [previous]))
        }
        return runs
    }

    /// The page box, grown to the painted extent of the ink, snapped outward to the 0.1 grid.
    public static func paintBox(_ page: NormalizedPage) throws -> Box {
        var corners: [(x: Double, y: Double)] = []
        for stroke in page.strokes {
            for run in try runs(stroke.points) {
                let radius = run.width / 2
                for point in run.points {
                    let x = try coord(point.x, "x"), y = try coord(point.y, "y")
                    corners.append((x - radius, y - radius))
                    corners.append((x + radius, y + radius))
                }
            }
        }
        let box = renderBox(page.geometry, ink: bounds(of: corners))
        let grid = pow(10, Double(coordDecimals))
        let left = (box.x * grid).rounded(.down), top = (box.y * grid).rounded(.down)
        let right = ((box.x + box.width) * grid).rounded(.up)
        let bottom = ((box.y + box.height) * grid).rounded(.up)
        return Box(x: left / grid, y: top / grid, width: (right - left) / grid, height: (bottom - top) / grid)
    }

    private static func pathData(_ run: Run) throws -> String {
        let first = run.points[0]
        let tail = run.points.count == 1 ? run.points[...] : run.points.dropFirst()
        var parts = ["M\(js(try coord(first.x, "x"))) \(js(try coord(first.y, "y")))"]
        for p in tail { parts.append("L\(js(try coord(p.x, "x"))) \(js(try coord(p.y, "y")))") }
        return parts.joined(separator: " ")
    }

    public static func render(_ page: NormalizedPage) throws -> String {
        let box = try paintBox(page)
        let viewBox = [box.x, box.y, box.width, box.height].map(js).joined(separator: " ")
        var parts = [
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(viewBox)\" width=\"\(js(box.width))\" height=\"\(js(box.height))\">",
            "<g fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\">",
        ]
        for stroke in page.strokes {
            let runs = try runs(stroke.points)
            if runs.isEmpty { continue }
            let color = stroke.style.color
            guard color.count == 7, color.hasPrefix("#"), color.dropFirst().allSatisfy(\.isHexDigit) else {
                throw Error.badColor(color)
            }
            let opacity = max(try round(stroke.style.opacity, opacityDecimals, "opacity"), minOpacity)
            if opacity < 1, runs.count > 1 {
                // one group so overlapping runs of one stroke don't darken each other
                parts.append("<g stroke=\"\(color)\" opacity=\"\(js(opacity))\">")
                for run in runs {
                    parts.append("<path d=\"\(try pathData(run))\" stroke-width=\"\(js(run.width))\"/>")
                }
                parts.append("</g>")
                continue
            }
            let fade = opacity < 1 ? " stroke-opacity=\"\(js(opacity))\"" : ""
            for run in runs {
                parts.append("<path d=\"\(try pathData(run))\" stroke=\"\(color)\"\(fade) stroke-width=\"\(js(run.width))\"/>")
            }
        }
        parts.append("</g>")
        parts.append("</svg>")
        return parts.joined(separator: "\n")
    }
}
