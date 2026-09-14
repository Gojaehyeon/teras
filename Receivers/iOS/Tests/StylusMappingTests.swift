import XCTest
import CoreGraphics
import TerasProtocol
@testable import TerasReceiver

/// The host builds tablet pressure and tilt from these fields, so they must
/// carry real measurements rather than zeros.
final class StylusMappingTests: XCTestCase {

    private let accuracy: Float = 0.0001

    private func pointer(force: CGFloat = 1,
                         maximumForce: CGFloat = 4,
                         altitude: CGFloat = .pi / 2,
                         azimuth: CGFloat = 0) -> TouchPointer {
        StylusMapping.pointer(id: 7, x: 0.25, y: 0.75,
                              force: force, maximumForce: maximumForce,
                              altitudeAngle: altitude, azimuthAngle: azimuth)
    }

    func testReportsStylusToolAndPosition() {
        let p = pointer()
        XCTAssertEqual(p.tool, .stylus)
        XCTAssertEqual(p.id, 7)
        XCTAssertEqual(p.x, 0.25, accuracy: accuracy)
        XCTAssertEqual(p.y, 0.75, accuracy: accuracy)
    }

    func testPressureIsForceOverMaximum() {
        XCTAssertEqual(pointer(force: 1, maximumForce: 4).pressure, 0.25, accuracy: accuracy)
        XCTAssertEqual(pointer(force: 4, maximumForce: 4).pressure, 1, accuracy: accuracy)
        XCTAssertEqual(pointer(force: 0, maximumForce: 4).pressure, 0, accuracy: accuracy)
    }

    func testPressureIsClampedAndSurvivesAZeroMaximum() {
        XCTAssertEqual(pointer(force: 9, maximumForce: 4).pressure, 1, accuracy: accuracy)
        XCTAssertEqual(pointer(force: -1, maximumForce: 4).pressure, 0, accuracy: accuracy)
        // A device that reports no maximum must not divide by zero.
        XCTAssertEqual(pointer(force: 2, maximumForce: 0).pressure, 1, accuracy: accuracy)
    }

    func testPerpendicularPencilHasNoTilt() {
        let p = pointer(altitude: .pi / 2, azimuth: 1.0)
        XCTAssertEqual(p.tiltX, 0, accuracy: accuracy)
        XCTAssertEqual(p.tiltY, 0, accuracy: accuracy)
    }

    func testFlatPencilTiltsFullyAlongItsAzimuth() {
        let alongX = pointer(altitude: 0, azimuth: 0)
        XCTAssertEqual(alongX.tiltX, .pi / 2, accuracy: 0.001)
        XCTAssertEqual(alongX.tiltY, 0, accuracy: 0.001)

        let alongY = pointer(altitude: 0, azimuth: .pi / 2)
        XCTAssertEqual(alongY.tiltX, 0, accuracy: 0.001)
        XCTAssertEqual(alongY.tiltY, .pi / 2, accuracy: 0.001)
    }

    func testHalfTiltSplitsBetweenBothAxes() {
        // 45 degrees from vertical, pointing diagonally.
        let p = pointer(altitude: .pi / 4, azimuth: .pi / 4)
        let tilt = Float.pi / 4
        let expected = tilt * Float(cos(Double.pi / 4))
        XCTAssertEqual(p.tiltX, expected, accuracy: 0.001)
        XCTAssertEqual(p.tiltY, expected, accuracy: 0.001)
    }

    func testTiltNeverGoesNegativeForOverVerticalAltitudes() {
        // Some devices report slightly more than pi/2; tilt must stay at zero.
        let p = pointer(altitude: .pi / 2 + 0.2, azimuth: 0)
        XCTAssertEqual(p.tiltX, 0, accuracy: accuracy)
        XCTAssertEqual(p.tiltY, 0, accuracy: accuracy)
    }

    func testAzimuthIsForwardedVerbatim() {
        XCTAssertEqual(pointer(azimuth: 2.5).azimuth, 2.5, accuracy: 0.001)
    }

    func testRealisticPencilStrokeProducesNonZeroFields() {
        // A pencil held at a natural angle must not serialise as flat zeros.
        let p = pointer(force: 2.2, maximumForce: 4.167, altitude: 0.9, azimuth: 1.2)
        XCTAssertGreaterThan(p.pressure, 0)
        XCTAssertNotEqual(p.tiltX, 0)
        XCTAssertNotEqual(p.tiltY, 0)
        XCTAssertNotEqual(p.azimuth, 0)

        // And it must survive a wire round trip unchanged.
        let event = TouchEvent(phase: .moved, pointers: [p])
        let decoded = try? TouchEvent(parsing: event.frame().payload)
        XCTAssertEqual(decoded, event)
    }

    func testFingerPointerIsAFingerAtFullPressure() {
        let p = StylusMapping.fingerPointer(id: 3, x: 0.5, y: 0.5)
        XCTAssertEqual(p.tool, .finger)
        XCTAssertEqual(p.pressure, 1, accuracy: accuracy)
        XCTAssertEqual(p.tiltX, 0, accuracy: accuracy)
        XCTAssertEqual(p.azimuth, 0, accuracy: accuracy)
    }
}
