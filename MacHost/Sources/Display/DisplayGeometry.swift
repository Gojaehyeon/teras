import Foundation
import TandemProtocol

/// Everything the host needs to build one virtual display and one encode
/// session for it. `encoded*` is what goes on the wire (physical pixels);
/// `logical*` is the desktop size macOS lays windows out in.
struct VirtualDisplaySpec: Equatable, Sendable {
    var encodedWidth: Int
    var encodedHeight: Int
    var logicalWidth: Int
    var logicalHeight: Int
    var hiDPI: Bool
    var refreshHz: Int

    var desktop: Size { Size(w: logicalWidth, h: logicalHeight) }
}

/// Pure geometry: HELLO_ACK screen description in, virtual-display spec out.
/// Kept free of CoreGraphics so it can be unit tested directly.
enum DisplayGeometry {
    /// Below this many points on either side, HiDPI leaves too little desktop
    /// to be useful, so we stay at 1x and give the user the bigger workspace.
    static let minLogicalDimension = 400

    /// Lowest and highest refresh we will drive a virtual display at.
    ///
    /// The ceiling is 60 because that is what CGVirtualDisplay actually
    /// delivers: asking for 120 on a ProMotion device gets the mode accepted
    /// but never honoured, so the receiver would be told to expect twice the
    /// frames the Mac can produce.
    static let minRefreshHz = 24
    static let maxRefreshHz = 60

    /// Pixel dimensions in the orientation the receiver is actually in.
    ///
    /// `ScreenInfo` is documented as already being in the current orientation,
    /// but receivers that report their panel's natural size are common enough
    /// that we transpose when the aspect disagrees with the stated orientation.
    static func orientedPixels(screen: ScreenInfo, orientation: Orientation) -> (w: Int, h: Int) {
        let w = max(1, screen.wPx)
        let h = max(1, screen.hPx)
        guard w != h else { return (w, h) }
        let reportsLandscape = w > h
        return reportsLandscape == orientation.isLandscape ? (w, h) : (h, w)
    }

    /// Refresh rate for the virtual display: the device's panel rate, clamped to
    /// what we support and to the user's frame-rate preference.
    static func refreshHz(screen: ScreenInfo, fpsCap: Int) -> Int {
        let panel = Int(screen.refreshHz.rounded())
        let bounded = min(max(panel, minRefreshHz), maxRefreshHz)
        return min(bounded, max(minRefreshHz, fpsCap))
    }

    /// Build the spec for a session.
    ///
    /// - Encoded size starts at the device's physical pixels, then is clamped to
    ///   the receiver's `maxDecode` box (or the codec's own ceiling) with the
    ///   aspect ratio preserved.
    /// - HiDPI is used when the device asks for it, its scale factor is at least
    ///   2, and half the encoded size still leaves a usable desktop. The logical
    ///   size is then exactly half the encoded size, which is what makes text on
    ///   the device as sharp as on a Retina Mac display.
    static func spec(screen: ScreenInfo,
                     orientation: Orientation,
                     codec: Codec,
                     maxDecode: Size?,
                     hiDPIRequested: Bool,
                     fpsCap: Int) -> VirtualDisplaySpec {
        let pixels = orientedPixels(screen: screen, orientation: orientation)

        let ceiling = CodecLimits.codecCeiling(codec)
        var (w, h) = CodecLimits.clamp(width: pixels.w, height: pixels.h,
                                       maxWidth: ceiling.width, maxHeight: ceiling.height)
        if let maxDecode {
            (w, h) = CodecLimits.clampToDecodeLimit(width: w, height: h, limit: maxDecode)
        }

        let wantsHiDPI = hiDPIRequested && screen.scale >= 2.0
        let halfW = (w / 2) & ~1
        let halfH = (h / 2) & ~1
        let hiDPI = wantsHiDPI && halfW >= minLogicalDimension && halfH >= minLogicalDimension

        let logicalW = hiDPI ? halfW : (w & ~1)
        let logicalH = hiDPI ? halfH : (h & ~1)
        // Keep encoded == 2 × logical exactly in HiDPI so the capture, the
        // encoder and the receiver all agree on the mapping.
        let encodedW = hiDPI ? logicalW * 2 : logicalW
        let encodedH = hiDPI ? logicalH * 2 : logicalH

        return VirtualDisplaySpec(encodedWidth: encodedW,
                                  encodedHeight: encodedH,
                                  logicalWidth: logicalW,
                                  logicalHeight: logicalH,
                                  hiDPI: hiDPI,
                                  refreshHz: refreshHz(screen: screen, fpsCap: fpsCap))
    }
}
