#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
import Testing
@testable import RMKit

@Suite struct PDFPlacementTests {
    func page(version: Int, portrait: PaperSize? = nil, orientation: Orientation = .portrait) -> NormalizedPage {
        NormalizedPage(strokes: [], drops: PageDrops(), geometry: PageGeometry(portrait: portrait, orientation: orientation), version: version)
    }

    @Test func v6InkIsAnchoredAtTheTopCentreAtAFixedScale() {
        let a4 = CGSize(width: 595, height: 842)
        let t = PDFPlacement.transform(for: page(version: 6), displayed: a4)
        // the screen's horizontal centre (x = 702 after normalize) lands on the page's centre
        #expect(CGPoint(x: 702, y: 0).applying(t) == CGPoint(x: 297.5, y: 0))
        // 227 px right and down is one inch: 72 pt
        let p = CGPoint(x: 702 + 227, y: 227).applying(t)
        #expect(abs(p.x - 369.5) < 1e-9 && abs(p.y - 72) < 1e-9)
        // the same holds on a Paper Pro page: only the centre moves
        let pp = PDFPlacement.transform(for: page(version: 6, portrait: PaperSize(width: 1620, height: 2160)), displayed: a4)
        #expect(CGPoint(x: 810, y: 0).applying(pp) == CGPoint(x: 297.5, y: 0))
    }

    @Test func v5InkFitsThePageToTheScreenFromTheTopLeft() {
        // Letter on the 1404×1872 screen: the width binds, and the page starts at the screen's corner
        let letter = CGSize(width: 612, height: 792)
        let t = PDFPlacement.transform(for: page(version: 5), displayed: letter)
        #expect(CGPoint(x: 0, y: 0).applying(t) == .zero)
        let s = 1404.0 / 612
        let right = CGPoint(x: 1404, y: 100 * s).applying(t)
        #expect(abs(right.x - 612) < 1e-9 && abs(right.y - 100) < 1e-9)
    }

    @Test func v5InkOnAWidePageIsTurnedUpright() {
        // a 1024×838 slide: the screen's top-left is the page's top-right; screen x runs down the page
        let slide = CGSize(width: 1024.6, height: 838.1)
        let t = PDFPlacement.transform(for: page(version: 5), displayed: slide)
        let s = min(1404 / 838.1, 1872 / 1024.6)
        let corner = CGPoint(x: 0, y: 0).applying(t)
        #expect(abs(corner.x - 1024.6) < 1e-9 && abs(corner.y) < 1e-9)
        let p = CGPoint(x: 100 * s, y: 200 * s).applying(t)
        #expect(abs(p.x - (1024.6 - 200)) < 1e-9 && abs(p.y - 100) < 1e-9)
    }

    @Test func v5InkInALandscapeDocumentLandsAsBeforeItWasTurned() {
        // normalize turns landscape v5 ink; placement must see the raw screen point again
        let letter = CGSize(width: 612, height: 792)
        let portrait = PDFPlacement.transform(for: page(version: 5), displayed: letter)
        let landscape = PDFPlacement.transform(for: page(version: 5, orientation: .landscape), displayed: letter)
        let raw = CGPoint(x: 300, y: 700)
        let turned = CGPoint(x: 1872 - raw.y, y: raw.x)
        let (a, b) = (raw.applying(portrait), turned.applying(landscape))
        #expect(abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9)
    }

    @Test func anInsertedPageIsTheScreenAtTheV6Scale() {
        let size = PDFPlacement.insertedPageSize(PageGeometry(portrait: nil, orientation: .portrait))
        #expect(abs(size.width - 1404 * 72 / 227) < 1e-9)
    }
}
#endif
