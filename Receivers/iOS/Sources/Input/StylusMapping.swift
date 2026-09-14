import Foundation
import CoreGraphics
import TandemProtocol

/// Apple Pencil geometry, mapped to the protocol's stylus fields
/// (PROTOCOL §6.1). Kept free of UIKit so the trigonometry is unit testable:
/// the host relies on these being real measurements, not placeholder zeros.
enum StylusMapping {

    /// `altitudeAngle` is 0 when the pencil lies flat on the glass and π/2
    /// when it stands perpendicular, so tilt away from vertical is
    /// `π/2 − altitude`. That tilt is then split along the azimuth direction.
    static func pointer(id: UInt32,
                        x: Float,
                        y: Float,
                        force: CGFloat,
                        maximumForce: CGFloat,
                        altitudeAngle: CGFloat,
                        azimuthAngle: CGFloat) -> TouchPointer {
        let pressure: Float
        if maximumForce > 0 {
            pressure = min(max(Float(force / maximumForce), 0), 1)
        } else {
            pressure = 1
        }

        let tiltFromVertical = max(0, (CGFloat.pi / 2) - altitudeAngle)
        let tiltX = Float(tiltFromVertical * cos(azimuthAngle))
        let tiltY = Float(tiltFromVertical * sin(azimuthAngle))

        return TouchPointer(id: id,
                            tool: .stylus,
                            x: x,
                            y: y,
                            pressure: pressure,
                            tiltX: tiltX,
                            tiltY: tiltY,
                            azimuth: Float(azimuthAngle))
    }

    static func fingerPointer(id: UInt32, x: Float, y: Float) -> TouchPointer {
        TouchPointer(id: id, tool: .finger, x: x, y: y, pressure: 1)
    }
}
