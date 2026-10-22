import Foundation
import Testing
@testable import RMKit

@Suite struct StrokesTests {
    func raw(_ pen: Pen, points: [RawPoint], hidden: Bool = false) -> RawStroke {
        RawStroke(pen: pen, color: .black, colorRgba: nil, thicknessScale: 1, points: points, id: nil, hidden: hidden)
    }

    @Test func v5PointsPassThroughInDevicePixels() throws {
        let ink = normalize(try parseRM(Fixtures.v5()), orientation: .portrait)
        #expect(ink.strokes.map(\.points) == [[
            StrokePoint(x: 10, y: 20, width: 2.5, pressure: 0.5),
            StrokePoint(x: 30, y: 40, width: 2.5, pressure: 0.5),
        ]])
    }

    @Test func v6IsCentredAndScaledByOrientation() {
        let point = RawPoint(x: 0, y: 5, speed: 0, direction: 0, width: 8, pressure: 255)
        let page = RMPage(version: 6, strokes: [raw(.fineliner, points: [point])], paperSize: nil, unreadableBlocks: 0)
        let landscape = normalize(page, orientation: .landscape)
        #expect(landscape.geometry.width == 1872)
        #expect(landscape.strokes[0].points == [StrokePoint(x: 936, y: 5, width: 2, pressure: 1)])
    }

    @Test func v5InALandscapeDocumentIsTurnedAQuarterClockwise() {
        let corners = [RawPoint(x: 0, y: 0, speed: 0, direction: 0, width: 2, pressure: 1),
                       RawPoint(x: 1404, y: 1872, speed: 0, direction: 0, width: 2, pressure: 1)]
        let page = RMPage(version: 5, strokes: [raw(.fineliner, points: corners)], paperSize: nil, unreadableBlocks: 0)
        let ink = normalize(page, orientation: .landscape)
        #expect(ink.geometry.width == 1872 && ink.geometry.height == 1404)
        // the portrait screen's top-left is the landscape page's top-right
        #expect(ink.strokes[0].points.map { [$0.x, $0.y] } == [[1872, 0], [0, 1404]])
    }

    @Test func countsWhatItLeavesOut() {
        let point = RawPoint(x: 1, y: 1, speed: 0, direction: 0, width: 4, pressure: 100)
        let page = RMPage(version: 6, strokes: [
            raw(.eraser, points: [point]),
            raw(.ballpoint, points: [point], hidden: true),
            raw(.ballpoint, points: []),
            raw(.ballpoint, points: [RawPoint(x: .nan, y: 1, speed: 0, direction: 0, width: 4, pressure: 1), point]),
        ], paperSize: nil, unreadableBlocks: 0)
        let ink = normalize(page, orientation: .portrait)
        #expect(ink.strokes.count == 1)
        #expect(ink.drops == PageDrops(eraserStrokes: 1, hiddenStrokes: 1, emptyStrokes: 1, nonFinitePoints: 1))
        #expect(ink.drops.isLossy)
    }
}
