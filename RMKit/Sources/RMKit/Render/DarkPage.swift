import CoreGraphics
import CoreImage
import Foundation
import simd

/// A page recoloured for Dark Mode: lightness turns over, colour stays. Each
/// colour's OKLab lightness is flipped onto a dark grey to off-white range,
/// keeping its hue and as much of its chroma as sRGB can show, so black ink
/// reads light, white paper goes dark, and red ink is still red.
public enum DarkPage {
    /// OKLab lightness white paper becomes: about #1e1e1e.
    static let paper = 0.235
    /// OKLab lightness black ink becomes: about #e0e0e0, softer than white on dark.
    static let ink = 0.9

    /// One sRGB colour, components 0...1, recoloured.
    static func darken(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let lab = OKLab(srgb: rgb)
        let lightness = paper + (1 - lab.l) * (ink - paper)
        // too much chroma at the new lightness falls outside sRGB: give up chroma, not hue
        var (low, high) = (0.0, 1.0)
        if !OKLab(l: lightness, a: lab.a, b: lab.b).inGamut {
            for _ in 0..<16 {
                let mid = (low + high) / 2
                if OKLab(l: lightness, a: lab.a * mid, b: lab.b * mid).inGamut { low = mid } else { high = mid }
            }
        } else {
            low = 1
        }
        let rgb = OKLab(l: lightness, a: lab.a * low, b: lab.b * low).srgb
        return simd_clamp(rgb, .zero, .one)
    }

    /// The colour paper becomes, for what's drawn around a dark page.
    public static let paperColor: CGColor = {
        let c = darken(.one)
        return CGColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1)
    }()

    static let cubeSize = 32

    /// `darken` sampled on an sRGB grid, as CIColorCube wants it: red fastest, RGBA floats.
    static let cube: Data = {
        let n = cubeSize
        var values = [Float]()
        values.reserveCapacity(n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let c = darken(SIMD3(Double(r), Double(g), Double(b)) / Double(n - 1))
                    values += [Float(c.x), Float(c.y), Float(c.z), 1]
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }()

    /// The filter that recolours, for a layer or an image. A new one each time: filters aren't shareable.
    public static func filter() -> CIFilter {
        let filter = CIFilter(name: "CIColorCubeWithColorSpace")!
        filter.setValue(cubeSize, forKey: "inputCubeDimension")
        filter.setValue(cube, forKey: "inputCubeData")
        filter.setValue(CGColorSpace(name: CGColorSpace.sRGB)!, forKey: "inputColorSpace")
        return filter
    }

    private static let context = CIContext()

    /// The image recoloured.
    public static func darken(_ image: CGImage) -> CGImage? {
        let filter = filter()
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}

/// Björn Ottosson's OKLab, from and to gamma-encoded sRGB.
struct OKLab {
    var l, a, b: Double

    init(l: Double, a: Double, b: Double) { (self.l, self.a, self.b) = (l, a, b) }

    init(srgb: SIMD3<Double>) {
        let c = srgb.map(Self.linear)
        let l = cbrt(0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z)
        let m = cbrt(0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z)
        let s = cbrt(0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z)
        self.l = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    var linear: SIMD3<Double> {
        let l = pow(self.l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(self.l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(self.l - 0.0894841775 * a - 1.2914855480 * b, 3)
        return SIMD3(
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    var inGamut: Bool {
        let c = linear
        return c.min() >= -1e-4 && c.max() <= 1 + 1e-4
    }

    var srgb: SIMD3<Double> { simd_clamp(linear, .zero, .one).map(Self.encoded) }

    static func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func encoded(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
}

private extension SIMD3<Double> {
    func map(_ f: (Double) -> Double) -> Self { Self(f(x), f(y), f(z)) }
}
