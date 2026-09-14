import Foundation
import TerasProtocol

//
//  Adapted from SideScreen (MIT licence) — MacHost/Sources/CodecLimits.swift.
//  Copyright (c) SideScreen contributors. See THIRD_PARTY_NOTICES.md.
//

enum CodecLimits {
    /// Conservative ceiling every AVC hardware decoder meets (H.264 level 4.x).
    /// Devices that only offer H.264 are low end; their real cap is at least this.
    static let avcMaxWidth = 1920
    static let avcMaxHeight = 1088

    /// Hard ceiling for the encode session regardless of what a receiver claims.
    static let absoluteMaxDimension = 4096

    /// Scale `(width, height)` down to fit `(maxWidth, maxHeight)` preserving the
    /// aspect ratio, flooring each side to a multiple of 16 for macroblock
    /// alignment. Sizes already inside the box pass through untouched.
    static func clamp(width: Int, height: Int, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0, maxWidth > 0, maxHeight > 0 else { return (16, 16) }
        guard width > maxWidth || height > maxHeight else { return (width, height) }
        let scale = min(Double(maxWidth) / Double(width), Double(maxHeight) / Double(height))
        let w = max(16, Int((Double(width) * scale).rounded()) & ~15)
        let h = max(16, Int((Double(height) * scale).rounded()) & ~15)
        return (w, h)
    }

    /// Clamp into a receiver-reported ceiling, transposing the box when its
    /// orientation differs from the capture's. Receivers report the ceiling in
    /// their panel's natural orientation, but it stands for a macroblock budget,
    /// which does not care which side is longer.
    static func clampToDecodeLimit(width: Int, height: Int, limit: Size) -> (width: Int, height: Int) {
        guard limit.w > 0, limit.h > 0 else { return (width, height) }
        let box = (height > width) == (limit.h > limit.w)
            ? (w: limit.w, h: limit.h)
            : (w: limit.h, h: limit.w)
        return clamp(width: width, height: height, maxWidth: box.w, maxHeight: box.h)
    }

    /// Ceiling for a codec when the receiver reported no decoder limit.
    static func codecCeiling(_ codec: Codec) -> (width: Int, height: Int) {
        switch codec {
        case .hevc: return (absoluteMaxDimension, absoluteMaxDimension)
        case .h264: return (avcMaxWidth, avcMaxHeight)
        }
    }
}
