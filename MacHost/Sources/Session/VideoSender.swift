import Foundation
import TerasProtocol

/// Turns encoded pictures into VIDEO frames and applies the send-side drop
/// policy. Called from the encoder's thread, so all state is behind a lock.
final class VideoSender: @unchecked Sendable {
    /// How many video frames may be waiting on the socket before we start
    /// dropping. Two frames is about 33 ms at 60 fps: past that, sending a
    /// stale picture costs more latency than skipping it.
    static let maxBacklog = 2

    private let channel: PeerChannel
    private let lock = NSLock()
    private var seq: UInt32 = 0
    private var dropped = 0
    private var pendingDiscontinuity = false
    private var stopped = false

    /// Invoked when frames were dropped and the stream needs a fresh IDR.
    /// Runs on the caller's thread.
    var onKeyframeNeeded: (() -> Void)?

    init(channel: PeerChannel) {
        self.channel = channel
    }

    var droppedFrameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }

    func stop() {
        lock.lock()
        stopped = true
        onKeyframeNeeded = nil
        lock.unlock()
    }

    func submit(_ encoded: EncodedFrame) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }

        if channel.videoBacklog > Self.maxBacklog, !encoded.isKeyframe {
            dropped += 1
            pendingDiscontinuity = true
            let notify = onKeyframeNeeded
            lock.unlock()
            // The receiver's decoder needs a clean restart point once we have
            // skipped pictures it was depending on.
            notify?()
            return
        }

        seq &+= 1
        let currentSeq = seq
        var flags: VideoFrame.Flags = []
        if encoded.isKeyframe { flags.insert(.keyframe) }
        if encoded.hasParameterSets { flags.insert(.hasParameterSets) }
        if pendingDiscontinuity {
            flags.insert(.discontinuity)
            pendingDiscontinuity = false
        }
        lock.unlock()

        let frame = VideoFrame(flags: flags,
                               captureTimestampUs: encoded.captureTimestampUs,
                               seq: currentSeq,
                               annexB: encoded.annexB)
        channel.sendVideo(frame.frame())
    }
}
