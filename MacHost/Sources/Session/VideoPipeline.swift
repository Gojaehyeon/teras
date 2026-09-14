import CoreGraphics
import CoreVideo
import Foundation
import TerasProtocol

/// Capture plus encode for one display. A protocol so the session's state
/// machine can be exercised without ScreenCaptureKit or VideoToolbox.
@MainActor
protocol VideoPipeline: AnyObject {
    /// Begin producing encoded frames. `onFrame` is called on the encoder's
    /// own thread, not the main thread.
    func start(displayID: CGDirectDisplayID,
               spec: VirtualDisplaySpec,
               codec: Codec,
               bitrateBps: Int,
               onFrame: @escaping (EncodedFrame) -> Void) async throws
    func stop()
    /// Make the next encoded picture an IDR.
    func requestKeyframe()
    /// Re-send the most recent picture, so a receiver that just asked for a
    /// keyframe is not left waiting on a static desktop.
    func replayLastFrame()
    func setBitrate(_ bitrateBps: Int)
    /// Description of the capture path in use, for the UI.
    var captureMethod: String { get }
}

/// The real pipeline: ScreenCaptureKit into VideoToolbox.
@MainActor
final class CaptureEncodePipeline: VideoPipeline {
    private var capturer: ScreenCapturer?
    private var encoder: VideoEncoder?
    private let encodeQueue = DispatchQueue(label: "app.teras.encode", qos: .userInteractive)
    private let inFlight = InFlightCounter()

    private(set) var captureMethod: String = "ScreenCaptureKit"

    /// Raised when capture dies in a way we cannot recover from.
    var onFatalError: ((Error) -> Void)?

    func start(displayID: CGDirectDisplayID,
               spec: VirtualDisplaySpec,
               codec: Codec,
               bitrateBps: Int,
               onFrame: @escaping (EncodedFrame) -> Void) async throws {
        stop()

        let encoder = try VideoEncoder(width: spec.encodedWidth,
                                       height: spec.encodedHeight,
                                       codec: codec,
                                       fps: spec.refreshHz,
                                       bitrateBps: bitrateBps)
        encoder.onEncodedFrame = onFrame
        self.encoder = encoder

        let capturer = ScreenCapturer(configuration: .init(displayID: displayID,
                                                           width: spec.encodedWidth,
                                                           height: spec.encodedHeight,
                                                           fps: spec.refreshHz))
        capturer.onCaptureMethodChanged = { [weak self] method in
            Task { @MainActor in self?.captureMethod = method }
        }
        capturer.onFatalError = { [weak self] error in
            Task { @MainActor in self?.onFatalError?(error) }
        }
        // Capture delivers on its own queue; hand frames to the encoder on the
        // encode queue and never let more than two pile up there, so a slow
        // encode drops frames instead of growing an unbounded backlog.
        capturer.onFrame = { [weak self] buffer, captureUs in
            guard let self else { return }
            guard self.inFlight.reserve(max: 2) else { return }
            let handoff = FrameHandoff(buffer: buffer, captureUs: captureUs)
            self.encodeQueue.async {
                encoder.encode(handoff.buffer, captureTimestampUs: handoff.captureUs)
                self.inFlight.release()
            }
        }
        self.capturer = capturer

        do {
            try await capturer.start()
        } catch {
            stop()
            throw error
        }
        // The first frame a receiver sees has to be a keyframe.
        encoder.requestKeyframe()
    }

    func stop() {
        capturer?.onFrame = nil
        capturer?.stop()
        capturer = nil
        encoder?.invalidate()
        encoder = nil
        inFlight.reset()
    }

    func requestKeyframe() {
        encoder?.requestKeyframe()
    }

    func replayLastFrame() {
        capturer?.replayLastFrame()
    }

    func setBitrate(_ bitrateBps: Int) {
        encoder?.setBitrate(bitrateBps)
    }
}

/// One captured picture on its way to the encoder. CoreVideo buffers are safe
/// to move between threads; they just carry no `Sendable` annotation.
private struct FrameHandoff: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let captureUs: UInt64
}

/// Counts frames handed to the encode queue.
private final class InFlightCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func reserve(max limit: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count < limit else { return false }
        count += 1
        return true
    }

    func release() {
        lock.lock()
        count = max(0, count - 1)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }
}
