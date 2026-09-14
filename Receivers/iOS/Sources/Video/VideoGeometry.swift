import Foundation
import CoreGraphics

/// Maps between view coordinates and the normalized coordinate space the
/// protocol uses for input (PROTOCOL §5.1: `[0,1]` over the *encoded video
/// frame*, origin top-left).
///
/// The renderer uses `AVLayerVideoGravityResizeAspect`, so the picture is
/// letterboxed or pillarboxed inside the view. Input must be normalized over
/// the rendered picture rect, not the view bounds.
enum VideoGeometry {

    /// Aspect-fit rect of `videoSize` inside `bounds`, matching `resizeAspect`.
    static func renderedRect(videoSize: CGSize, in bounds: CGRect) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let width = videoSize.width * scale
        let height = videoSize.height * scale
        let x = bounds.minX + (bounds.width - width) / 2
        let y = bounds.minY + (bounds.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Normalizes a point in view coordinates over the rendered picture rect,
    /// clamped to `[0,1]`. Returns nil when the rect is degenerate.
    static func normalize(_ point: CGPoint, in rect: CGRect) -> CGPoint? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    /// Convenience: view point → normalized video coordinate.
    static func normalize(_ point: CGPoint, videoSize: CGSize, bounds: CGRect) -> CGPoint? {
        normalize(point, in: renderedRect(videoSize: videoSize, in: bounds))
    }
}
