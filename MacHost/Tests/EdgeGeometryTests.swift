import CoreGraphics
import XCTest
@testable import TerasCore

/// The capture rules from CONTROL.md §7, exercised without an event tap.
final class EdgeGeometryTests: XCTestCase {

    /// One 1440×900 display at the origin, a 1080×2400 phone on the right.
    private func rightGeometry(speed: CGFloat = 1.5) -> EdgeGeometry {
        EdgeGeometry(displayUnion: CGRect(x: 0, y: 0, width: 1440, height: 900),
                     edge: .right,
                     phoneSize: CGSize(width: 1080, height: 2400),
                     speed: speed)
    }

    private func leftGeometry() -> EdgeGeometry {
        EdgeGeometry(displayUnion: CGRect(x: 0, y: 0, width: 1440, height: 900),
                     edge: .left,
                     phoneSize: CGSize(width: 1080, height: 2400),
                     speed: 1.5)
    }

    // MARK: - Crossing

    func testRightEdgeCrossesOnlyWhenPushingOutwardFromTheEdgeColumn() {
        let geometry = rightGeometry()
        XCTAssertTrue(geometry.crossesEdge(cursor: CGPoint(x: 1439, y: 400), deltaX: 3))
        XCTAssertFalse(geometry.crossesEdge(cursor: CGPoint(x: 1439, y: 400), deltaX: 0),
                       "resting on the edge is not a crossing")
        XCTAssertFalse(geometry.crossesEdge(cursor: CGPoint(x: 1439, y: 400), deltaX: -5),
                       "moving back inward is not a crossing")
        XCTAssertFalse(geometry.crossesEdge(cursor: CGPoint(x: 1000, y: 400), deltaX: 20),
                       "a fast move in the middle of the desktop is not a crossing")
    }

    func testCrossingNeedsAtLeastOnePixel() {
        let geometry = rightGeometry()
        XCTAssertFalse(geometry.crossesEdge(cursor: CGPoint(x: 1439, y: 400), deltaX: 0.5))
        XCTAssertTrue(geometry.crossesEdge(cursor: CGPoint(x: 1439, y: 400), deltaX: 1))
    }

    func testLeftEdgeCrossesOnTheOtherSide() {
        let geometry = leftGeometry()
        XCTAssertTrue(geometry.crossesEdge(cursor: CGPoint(x: 0, y: 400), deltaX: -2))
        XCTAssertFalse(geometry.crossesEdge(cursor: CGPoint(x: 0, y: 400), deltaX: 2))
        XCTAssertFalse(geometry.crossesEdge(cursor: CGPoint(x: 1439, y: 400), deltaX: -2))
    }

    func testCrossingIgnoresCursorOutsideTheVerticalRange() {
        var geometry = rightGeometry()
        geometry.displayUnion = CGRect(x: 0, y: 100, width: 1440, height: 900)
        XCTAssertFalse(geometry.crossesEdge(cursor: CGPoint(x: 1439, y: 50), deltaX: 5))
        XCTAssertTrue(geometry.crossesEdge(cursor: CGPoint(x: 1439, y: 150), deltaX: 5))
    }

    // MARK: - Entry

    func testEntryPointIsTheFacingEdgeAtProportionalHeight() {
        let geometry = rightGeometry()
        let entry = geometry.entryPoint(cursorY: 450)   // halfway down the Mac
        XCTAssertEqual(entry.x, 0, "a phone on the right is entered from its left edge")
        XCTAssertEqual(entry.y, 1200, accuracy: 0.001)
    }

    func testEntryPointForALeftHandPhoneIsTheRightEdge() {
        let entry = leftGeometry().entryPoint(cursorY: 0)
        XCTAssertEqual(entry.x, 1079)
        XCTAssertEqual(entry.y, 0)
    }

    func testEntryPointClampsToThePhone() {
        let geometry = rightGeometry()
        XCTAssertEqual(geometry.entryPoint(cursorY: 899).y, 2397.333, accuracy: 0.01)
        XCTAssertEqual(geometry.entryPoint(cursorY: 100_000).y, 2399)
    }

    // MARK: - Movement

    func testMoveScalesByTheSpeedFactor() {
        let geometry = rightGeometry(speed: 1.5)
        let result = geometry.move(from: CGPoint(x: 100, y: 100), deltaX: 10, deltaY: -4)
        XCTAssertFalse(result.release)
        XCTAssertEqual(result.point.x, 115)
        XCTAssertEqual(result.point.y, 94)
    }

    func testMoveClampsInsideThePhone() {
        let geometry = rightGeometry(speed: 1)
        let right = geometry.move(from: CGPoint(x: 1070, y: 10), deltaX: 500, deltaY: 0)
        XCTAssertEqual(right.point.x, 1079, "clamped to the last column")
        XCTAssertFalse(right.release, "the far edge is a wall, not a way back")

        let top = geometry.move(from: CGPoint(x: 10, y: 5), deltaX: 0, deltaY: -500)
        XCTAssertEqual(top.point.y, 0)
        XCTAssertFalse(top.release)

        let bottom = geometry.move(from: CGPoint(x: 10, y: 2390), deltaX: 0, deltaY: 500)
        XCTAssertEqual(bottom.point.y, 2399)
    }

    func testMovePastTheFacingEdgeReleases() {
        let geometry = rightGeometry(speed: 1)
        let result = geometry.move(from: CGPoint(x: 3, y: 500), deltaX: -10, deltaY: 0)
        XCTAssertTrue(result.release)
        XCTAssertEqual(result.point.x, 0, "still reported inside the phone")
    }

    func testLeftHandPhoneReleasesPastItsRightEdge() {
        let geometry = leftGeometry()
        XCTAssertTrue(geometry.move(from: CGPoint(x: 1079, y: 10), deltaX: 10, deltaY: 0).release)
        XCTAssertFalse(geometry.move(from: CGPoint(x: 5, y: 10), deltaX: -10, deltaY: 0).release)
    }

    // MARK: - Pin and release

    func testPinPointSitsOnTheEdgeColumn() {
        XCTAssertEqual(rightGeometry().pinPoint(cursorY: 400), CGPoint(x: 1439, y: 400))
        XCTAssertEqual(leftGeometry().pinPoint(cursorY: 400), CGPoint(x: 0, y: 400))
    }

    func testPinPointClampsTheHeight() {
        XCTAssertEqual(rightGeometry().pinPoint(cursorY: 5000).y, 899)
        XCTAssertEqual(rightGeometry().pinPoint(cursorY: -20).y, 0)
    }

    func testReleaseCursorPointIsJustInsideTheEdge() {
        let right = rightGeometry().releaseCursorPoint(virtualY: 1200)
        XCTAssertEqual(right.x, 1440 - EdgeGeometry.releaseInset)
        XCTAssertEqual(right.y, 450, accuracy: 0.001)

        let left = leftGeometry().releaseCursorPoint(virtualY: 0)
        XCTAssertEqual(left.x, EdgeGeometry.releaseInset)
        XCTAssertEqual(left.y, 0)
    }

    func testEntryAndReleaseAreInverses() {
        let geometry = rightGeometry()
        let entry = geometry.entryPoint(cursorY: 300)
        let back = geometry.releaseCursorPoint(virtualY: entry.y)
        XCTAssertEqual(back.y, 300, accuracy: 0.5)
    }

    // MARK: - Multiple displays

    func testEdgeFollowsTheRightMostDisplay() {
        var geometry = rightGeometry()
        geometry.displayUnion = CGRect(x: -1920, y: 0, width: 1920 + 1440, height: 1080)
        XCTAssertEqual(geometry.edgeX, 1440)
        XCTAssertTrue(geometry.crossesEdge(cursor: CGPoint(x: 1439, y: 10), deltaX: 2))
        XCTAssertFalse(geometry.crossesEdge(cursor: CGPoint(x: -1920, y: 10), deltaX: -2))

        geometry.edge = .left
        XCTAssertEqual(geometry.edgeX, -1920)
        XCTAssertTrue(geometry.crossesEdge(cursor: CGPoint(x: -1920, y: 10), deltaX: -2))
    }

    // MARK: - Scroll conversion

    func testScrollStepsAreTenPointsPerNotch() {
        XCTAssertEqual(ControlScroll.steps(points: 10, invert: false), 1, accuracy: 0.0001)
        XCTAssertEqual(ControlScroll.steps(points: -25, invert: false), -2.5, accuracy: 0.0001)
        XCTAssertEqual(ControlScroll.steps(points: 10, invert: true), -1, accuracy: 0.0001)
    }
}
