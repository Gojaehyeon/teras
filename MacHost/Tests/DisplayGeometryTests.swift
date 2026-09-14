import XCTest
import TandemProtocol
@testable import TandemCore

final class DisplayGeometryTests: XCTestCase {

    private func screen(_ w: Int, _ h: Int, scale: Double = 3, hz: Double = 120) -> ScreenInfo {
        ScreenInfo(wPx: w, hPx: h, scale: scale, refreshHz: hz)
    }

    // MARK: - Orientation

    func testOrientedPixelsPassThroughWhenAspectAgrees() {
        let portrait = DisplayGeometry.orientedPixels(screen: screen(1179, 2556), orientation: .portrait)
        XCTAssertEqual(portrait.w, 1179)
        XCTAssertEqual(portrait.h, 2556)

        let landscape = DisplayGeometry.orientedPixels(screen: screen(2556, 1179), orientation: .landscapeLeft)
        XCTAssertEqual(landscape.w, 2556)
        XCTAssertEqual(landscape.h, 1179)
    }

    func testOrientedPixelsSwapWhenTheDeviceReportsItsNaturalSize() {
        // Receiver reported the panel's portrait size but says it is landscape.
        let swapped = DisplayGeometry.orientedPixels(screen: screen(1179, 2556), orientation: .landscapeRight)
        XCTAssertEqual(swapped.w, 2556)
        XCTAssertEqual(swapped.h, 1179)
    }

    // MARK: - HiDPI

    func testHiDPIHalvesTheDesktopAndKeepsEncodedAtExactlyDouble() {
        let spec = DisplayGeometry.spec(screen: screen(2556, 1179),
                                        orientation: .landscapeLeft,
                                        codec: .hevc,
                                        maxDecode: nil,
                                        hiDPIRequested: true,
                                        fpsCap: 60)
        XCTAssertTrue(spec.hiDPI)
        XCTAssertEqual(spec.logicalWidth * 2, spec.encodedWidth)
        XCTAssertEqual(spec.logicalHeight * 2, spec.encodedHeight)
        XCTAssertEqual(spec.logicalWidth, 1278)
        XCTAssertEqual(spec.logicalHeight, 588)
        XCTAssertEqual(spec.desktop, Size(w: 1278, h: 588))
    }

    func testHiDPIIsOffWhenTheDeviceIsNotRetina() {
        let spec = DisplayGeometry.spec(screen: screen(1920, 1080, scale: 1),
                                        orientation: .landscapeLeft,
                                        codec: .hevc,
                                        maxDecode: nil,
                                        hiDPIRequested: true,
                                        fpsCap: 60)
        XCTAssertFalse(spec.hiDPI)
        XCTAssertEqual(spec.encodedWidth, 1920)
        XCTAssertEqual(spec.logicalWidth, 1920)
    }

    func testHiDPIIsOffWhenTheUserTurnedItOff() {
        let spec = DisplayGeometry.spec(screen: screen(2556, 1179),
                                        orientation: .landscapeLeft,
                                        codec: .hevc,
                                        maxDecode: nil,
                                        hiDPIRequested: false,
                                        fpsCap: 60)
        XCTAssertFalse(spec.hiDPI)
        XCTAssertEqual(spec.encodedWidth, 2556)
        XCTAssertEqual(spec.logicalWidth, 2556)
    }

    func testHiDPIIsOffWhenHalfTheScreenWouldBeTooSmall() {
        // A small watch-sized panel: half of it is not a usable desktop.
        let spec = DisplayGeometry.spec(screen: screen(640, 700, scale: 3),
                                        orientation: .portrait,
                                        codec: .hevc,
                                        maxDecode: nil,
                                        hiDPIRequested: true,
                                        fpsCap: 60)
        XCTAssertFalse(spec.hiDPI)
    }

    // MARK: - Decoder limits

    func testMaxDecodeScalesDownAndKeepsAspect() {
        let spec = DisplayGeometry.spec(screen: screen(2732, 2048, scale: 2),
                                        orientation: .landscapeLeft,
                                        codec: .hevc,
                                        maxDecode: Size(w: 1920, h: 1088),
                                        hiDPIRequested: false,
                                        fpsCap: 60)
        XCTAssertLessThanOrEqual(spec.encodedWidth, 1920)
        XCTAssertLessThanOrEqual(spec.encodedHeight, 1088)

        let sourceAspect = 2732.0 / 2048.0
        let resultAspect = Double(spec.encodedWidth) / Double(spec.encodedHeight)
        XCTAssertEqual(resultAspect, sourceAspect, accuracy: 0.02)
    }

    func testMaxDecodeBoxIsTransposedWhenOrientationDiffers() {
        // Receiver reports its ceiling in portrait; we are streaming landscape.
        let spec = DisplayGeometry.spec(screen: screen(3200, 1800, scale: 2),
                                        orientation: .landscapeLeft,
                                        codec: .hevc,
                                        maxDecode: Size(w: 1088, h: 1920),
                                        hiDPIRequested: false,
                                        fpsCap: 60)
        XCTAssertLessThanOrEqual(spec.encodedWidth, 1920)
        XCTAssertLessThanOrEqual(spec.encodedHeight, 1088)
    }

    func testH264FallsBackToTheConservativeAvcCeiling() {
        let spec = DisplayGeometry.spec(screen: screen(2556, 1179, scale: 3),
                                        orientation: .landscapeLeft,
                                        codec: .h264,
                                        maxDecode: nil,
                                        hiDPIRequested: false,
                                        fpsCap: 60)
        XCTAssertLessThanOrEqual(spec.encodedWidth, CodecLimits.avcMaxWidth)
        XCTAssertLessThanOrEqual(spec.encodedHeight, CodecLimits.avcMaxHeight)
    }

    func testHevcIsCappedByTheAbsoluteCeiling() {
        let spec = DisplayGeometry.spec(screen: screen(7680, 4320, scale: 2),
                                        orientation: .landscapeLeft,
                                        codec: .hevc,
                                        maxDecode: nil,
                                        hiDPIRequested: false,
                                        fpsCap: 60)
        XCTAssertLessThanOrEqual(spec.encodedWidth, CodecLimits.absoluteMaxDimension)
        XCTAssertLessThanOrEqual(spec.encodedHeight, CodecLimits.absoluteMaxDimension)
    }

    // MARK: - Refresh rate

    func testRefreshIsTheLowerOfPanelAndUserPreference() {
        XCTAssertEqual(DisplayGeometry.refreshHz(screen: screen(1, 1, hz: 120), fpsCap: 60), 60)
        XCTAssertEqual(DisplayGeometry.refreshHz(screen: screen(1, 1, hz: 60), fpsCap: 60), 60)
        XCTAssertEqual(DisplayGeometry.refreshHz(screen: screen(1, 1, hz: 60), fpsCap: 30), 30)
        // CGVirtualDisplay tops out at 60, so a 90 Hz panel still gets 60.
        XCTAssertEqual(DisplayGeometry.refreshHz(screen: screen(1, 1, hz: 90), fpsCap: 120), 60)
        XCTAssertEqual(DisplayGeometry.maxRefreshHz, 60, "CGVirtualDisplay does not honour more")
    }

    func testRefreshIsClampedIntoTheSupportedRange() {
        XCTAssertEqual(DisplayGeometry.refreshHz(screen: screen(1, 1, hz: 0), fpsCap: 60),
                       DisplayGeometry.minRefreshHz)
        XCTAssertEqual(DisplayGeometry.refreshHz(screen: screen(1, 1, hz: 240), fpsCap: 240),
                       DisplayGeometry.maxRefreshHz)
    }

    // MARK: - Dimensions stay codec friendly

    func testEncodedDimensionsAreEven() {
        for (w, h) in [(1179, 2556), (1080, 2400), (2048, 2732), (1234, 567)] {
            let spec = DisplayGeometry.spec(screen: screen(w, h, scale: 3),
                                            orientation: h > w ? .portrait : .landscapeLeft,
                                            codec: .hevc,
                                            maxDecode: nil,
                                            hiDPIRequested: true,
                                            fpsCap: 60)
            XCTAssertEqual(spec.encodedWidth % 2, 0, "\(w)x\(h)")
            XCTAssertEqual(spec.encodedHeight % 2, 0, "\(w)x\(h)")
            XCTAssertGreaterThan(spec.logicalWidth, 0)
            XCTAssertGreaterThan(spec.logicalHeight, 0)
        }
    }

    // MARK: - Product and serial identity

    func testProductIdDistinguishesPortraitFromLandscape() {
        XCTAssertNotEqual(VirtualDisplay.productID(width: 2556, height: 1179),
                          VirtualDisplay.productID(width: 1179, height: 2556))
    }

    func testSerialNumberIsStablePerDeviceAndNeverZero() {
        let a = VirtualDisplay.serialNumber(forDeviceId: "22222222-2222-2222-2222-222222222222")
        let b = VirtualDisplay.serialNumber(forDeviceId: "22222222-2222-2222-2222-222222222222")
        let c = VirtualDisplay.serialNumber(forDeviceId: "33333333-3333-3333-3333-333333333333")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, 0)
        XCTAssertNotEqual(VirtualDisplay.serialNumber(forDeviceId: ""), 0)
    }
}
