import Foundation
import TerasProtocol

/// The decoder/renderer seen from the session state machine.
protocol VideoSink: AnyObject {
    /// Called on STREAM_CONFIG. Must reset the decoder when codec or size change.
    func configure(_ config: StreamConfig)
    /// Called for every VIDEO frame. `hostClockOffsetUs` converts the host's
    /// capture timestamp into the receiver's monotonic clock for e2e stats.
    func enqueue(_ frame: VideoFrame, hostClockOffsetUs: Int64?)
    /// Tear the pipeline down and show nothing.
    func reset()
    /// STATS source, sampled once a second.
    func snapshotStats() -> VideoStatsSnapshot
}
