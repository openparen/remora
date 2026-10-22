import CoreGraphics
import Foundation

/// Where a page's ink lands on a PDF page. Measured on the user's documents:
/// v6 ink is anchored to the page at a fixed scale from the top centre of
/// its crop box, whatever the device or zoom. v3/v5 ink was drawn on the page
/// fitted to the 1404×1872 screen from its top-left, a wide page first turned
/// to stand upright on the screen.
public enum PDFPlacement {
    /// PDF points per device pixel for v6 ink. The tablet lays PDFs out at
    /// 227 dpi (rmc and remarks use 226; 227 fits highlights measurably better).
    public static let pointsPerPixel = 72.0 / 227

    /// Maps normalized page coordinates (as `normalize` makes them) to the
    /// displayed page, in points with the origin top-left and y down. The
    /// displayed size is the crop box with any /Rotate applied.
    public static func transform(for page: NormalizedPage, displayed: CGSize) -> CGAffineTransform {
        if page.version == 6 {
            // u = Wd/2 + (x − W/2)·k, v = y·k; ink outside the page stays outside, not clipped
            let k = pointsPerPixel
            return CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: displayed.width / 2 - page.geometry.width / 2 * k, ty: 0)
        }
        // v3/v5: measured in the portrait screen's coordinates; normalize turned a landscape document's ink, so turn it back
        // ponytail: v3/v5 ink in a landscape-orientation PDF document is unmeasured; it's placed as on a portrait one
        let screen = page.geometry.orientation == .landscape
            ? CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: page.geometry.width)
            : .identity
        return screen.concatenating(fitted(displayed))
    }

    /// v3/v5: the page fitted to the portrait screen, anchored top-left, not centred.
    private static func fitted(_ displayed: CGSize) -> CGAffineTransform {
        let (w, h) = (displayed.width, displayed.height)
        if w <= h {
            let s = min(1404 / w, 1872 / h)
            return CGAffineTransform(scaleX: 1 / s, y: 1 / s)
        }
        // a wide page stood on its side: screen x runs down the page, screen y runs right to left
        let s = min(1404 / h, 1872 / w)
        return CGAffineTransform(a: 0, b: 1 / s, c: -1 / s, d: 0, tx: w, ty: 0)
    }

    /// The size of a page with no source PDF page (one inserted on the tablet):
    /// the screen at the v6 scale, so its ink lands as it would on paper.
    public static func insertedPageSize(_ geometry: PageGeometry) -> CGSize {
        CGSize(width: geometry.width * pointsPerPixel, height: geometry.height * pointsPerPixel)
    }
}
