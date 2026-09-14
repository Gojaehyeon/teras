import XCTest
import CoreGraphics
@testable import TerasReceiver

final class VideoGeometryTests: XCTestCase {

    func testLetterboxesWideVideoInSquareBounds() {
        let rect = VideoGeometry.renderedRect(videoSize: CGSize(width: 200, height: 100),
                                              in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(rect, CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    func testPillarboxesTallVideoInSquareBounds() {
        let rect = VideoGeometry.renderedRect(videoSize: CGSize(width: 100, height: 200),
                                              in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(rect, CGRect(x: 25, y: 0, width: 50, height: 100))
    }

    func testExactAspectMatchFillsBounds() {
        let rect = VideoGeometry.renderedRect(videoSize: CGSize(width: 2556, height: 1179),
                                              in: CGRect(x: 0, y: 0, width: 852, height: 393))
        XCTAssertEqual(rect.width, 852, accuracy: 0.001)
        XCTAssertEqual(rect.height, 393, accuracy: 0.001)
        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
    }

    func testDegenerateInputsFallBackToBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(VideoGeometry.renderedRect(videoSize: .zero, in: bounds), bounds)
        XCTAssertEqual(VideoGeometry.renderedRect(videoSize: CGSize(width: 10, height: 10), in: .zero), .zero)
    }

    func testNormalizesOverLetterboxedRect() {
        let video = CGSize(width: 200, height: 100)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

        let center = VideoGeometry.normalize(CGPoint(x: 50, y: 50), videoSize: video, bounds: bounds)
        XCTAssertEqual(center?.x ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(center?.y ?? -1, 0.5, accuracy: 0.0001)

        let topLeftOfPicture = VideoGeometry.normalize(CGPoint(x: 0, y: 25), videoSize: video, bounds: bounds)
        XCTAssertEqual(topLeftOfPicture?.x ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(topLeftOfPicture?.y ?? -1, 0, accuracy: 0.0001)

        let bottomRightOfPicture = VideoGeometry.normalize(CGPoint(x: 100, y: 75), videoSize: video, bounds: bounds)
        XCTAssertEqual(bottomRightOfPicture?.x ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(bottomRightOfPicture?.y ?? -1, 1, accuracy: 0.0001)
    }

    func testClampsTouchesInTheLetterboxBars() {
        let video = CGSize(width: 200, height: 100)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

        let aboveThePicture = VideoGeometry.normalize(CGPoint(x: 50, y: 0), videoSize: video, bounds: bounds)
        XCTAssertEqual(aboveThePicture?.y ?? -1, 0, accuracy: 0.0001)

        let belowThePicture = VideoGeometry.normalize(CGPoint(x: 50, y: 100), videoSize: video, bounds: bounds)
        XCTAssertEqual(belowThePicture?.y ?? -1, 1, accuracy: 0.0001)
    }

    func testNormalizeRejectsEmptyRect() {
        XCTAssertNil(VideoGeometry.normalize(CGPoint(x: 1, y: 1), in: .zero))
    }

    func testNormalizeHonoursRectOrigin() {
        let rect = CGRect(x: 40, y: 10, width: 80, height: 40)
        let point = VideoGeometry.normalize(CGPoint(x: 80, y: 30), in: rect)
        XCTAssertEqual(point?.x ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(point?.y ?? -1, 0.5, accuracy: 0.0001)
    }
}
