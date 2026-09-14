import Foundation
import UIKit
import AVFoundation
import CoreMedia
import TandemProtocol

/// A `UIView` backed by `AVSampleBufferDisplayLayer` that turns VIDEO frames
/// into pictures.
///
/// Threading: every layer interaction happens on `videoQueue`. The view's
/// bounds are mirrored into `boundsSnapshot` from the main thread so the input
/// overlay can compute the rendered picture rect without hopping queues.
final class VideoRendererView: UIView, VideoSink {

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    private var displayLayer: AVSampleBufferDisplayLayer {
        // `layerClass` guarantees the type.
        guard let layer = layer as? AVSampleBufferDisplayLayer else {
            preconditionFailure("layerClass must be AVSampleBufferDisplayLayer")
        }
        return layer
    }

    /// Invoked when the pipeline needs the host to send a fresh IDR.
    var onKeyframeNeeded: (() -> Void)?

    /// Throttle between KEYFRAME_REQUEST frames.
    static let keyframeRequestInterval: TimeInterval = 0.5

    private let videoQueue = DispatchQueue(label: "app.tandem.receiver.video", qos: .userInteractive)

    // Pipeline state; touched on videoQueue only.
    private var codec: Codec = .h264
    private var configuredSize = CGSize.zero
    private var formatDescription: CMVideoFormatDescription?
    private var lastParameterSets = AnnexB.ParameterSets()
    private var inFlight = 0
    private var hasKeyframe = false
    private var keyframeRequestedAt: TimeInterval = 0

    // Stats; guarded by statsLock.
    private let statsLock = NSLock()
    private var decodedWindow = RollingWindow()
    private var droppedWindow = RollingWindow()
    private var decodeMsWindow = RollingWindow()
    private var e2eMsWindow = RollingWindow()
    private var lastQueued = 0

    /// Encoded video size, set by STREAM_CONFIG. Read from any thread.
    private let sizeLock = NSLock()
    private var videoSizeStorage = CGSize.zero
    private var codecNameStorage = ""
    var videoSize: CGSize {
        sizeLock.lock(); defer { sizeLock.unlock() }
        return videoSizeStorage
    }

    private let boundsLock = NSLock()
    private var boundsStorage = CGRect.zero
    /// Latest view bounds, safe to read off the main thread.
    var boundsSnapshot: CGRect {
        boundsLock.lock(); defer { boundsLock.unlock() }
        return boundsStorage
    }

    /// The rect the picture actually occupies, accounting for letterboxing.
    var renderedVideoRect: CGRect {
        VideoGeometry.renderedRect(videoSize: videoSize, in: boundsSnapshot)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .black
        isOpaque = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        boundsLock.lock()
        boundsStorage = bounds
        boundsLock.unlock()
    }

    // MARK: - VideoSink

    func configure(_ config: StreamConfig) {
        let size = CGSize(width: config.wPx, height: config.hPx)
        sizeLock.lock()
        videoSizeStorage = size
        codecNameStorage = config.codec.rawValue
        sizeLock.unlock()

        videoQueue.async { [weak self] in
            guard let self else { return }
            let changed = self.codec != config.codec || self.configuredSize != size
            self.codec = config.codec
            self.configuredSize = size
            if changed {
                self.resetPipelineLocked()
            }
        }
    }

    func reset() {
        sizeLock.lock()
        videoSizeStorage = .zero
        codecNameStorage = ""
        sizeLock.unlock()
        videoQueue.async { [weak self] in
            self?.resetPipelineLocked()
        }
        statsLock.lock()
        decodedWindow = RollingWindow()
        droppedWindow = RollingWindow()
        decodeMsWindow = RollingWindow()
        e2eMsWindow = RollingWindow()
        lastQueued = 0
        statsLock.unlock()
    }

    func enqueue(_ frame: VideoFrame, hostClockOffsetUs: Int64?) {
        videoQueue.async { [weak self] in
            self?.process(frame, hostClockOffsetUs: hostClockOffsetUs)
        }
    }

    func snapshotStats() -> VideoStatsSnapshot {
        let now = CACurrentMediaTime()
        statsLock.lock()
        defer { statsLock.unlock() }
        var snapshot = VideoStatsSnapshot()
        snapshot.fpsDecoded = Double(decodedWindow.count(now: now))
        snapshot.fpsDropped = Double(droppedWindow.count(now: now))
        snapshot.decodeMsP50 = decodeMsWindow.percentile50(now: now)
        let e2eCount = e2eMsWindow.count(now: now)
        snapshot.e2eMsP50 = e2eCount > 0 ? e2eMsWindow.percentile50(now: now) : nil
        snapshot.queued = lastQueued
        let size = videoSize
        snapshot.width = Int(size.width)
        snapshot.height = Int(size.height)
        snapshot.codec = codecName
        return snapshot
    }

    private var codecName: String {
        sizeLock.lock(); defer { sizeLock.unlock() }
        return codecNameStorage
    }

    // MARK: - Pipeline

    private func resetPipelineLocked() {
        formatDescription = nil
        lastParameterSets = AnnexB.ParameterSets()
        hasKeyframe = false
        inFlight = 0
        flushLayer()
    }

    private func process(_ frame: VideoFrame, hostClockOffsetUs: Int64?) {
        let started = CACurrentMediaTime()

        if frame.flags.contains(.discontinuity) {
            flushLayer()
            inFlight = 0
            hasKeyframe = false
            formatDescription = nil
        }

        if let failure = layerFailure() {
            NSLog("[Tandem] display layer failed: \(failure.localizedDescription)")
            flushLayer()
            formatDescription = nil
            hasKeyframe = false
            inFlight = 0
            requestKeyframe(now: started)
        }

        // Rebuild the format description from the parameter sets on every
        // keyframe: the host may change resolution without a STREAM_CONFIG
        // round trip, and a stale description shows garbage.
        if frame.flags.contains(.keyframe) || frame.flags.contains(.hasParameterSets) || formatDescription == nil {
            let sets = AnnexB.parameterSets(in: frame.annexB, codec: codec)
            if sets.isComplete(for: codec), sets != lastParameterSets || formatDescription == nil {
                if let description = VideoFormatFactory.makeFormatDescription(codec: codec, sets: sets) {
                    if formatDescription != nil { flushLayer() }
                    formatDescription = description
                    lastParameterSets = sets
                } else {
                    NSLog("[Tandem] could not build a format description from the parameter sets")
                }
            }
        }

        guard let description = formatDescription else {
            // Nothing decodable yet; ask for a keyframe with parameter sets.
            requestKeyframe(now: started)
            recordDropped(now: started)
            return
        }

        if !hasKeyframe {
            guard frame.flags.contains(.keyframe) || AnnexB.containsKeyframe(in: frame.annexB, codec: codec) else {
                requestKeyframe(now: started)
                recordDropped(now: started)
                return
            }
            hasKeyframe = true
        }

        let sampleData = AnnexB.lengthPrefixed(frame.annexB, codec: codec)
        guard !sampleData.isEmpty else {
            recordDropped(now: started)
            return
        }

        let presentationTime = CMTime(value: CMTimeValue(frame.captureTimestampUs), timescale: 1_000_000)
        guard let sample = VideoFormatFactory.makeSampleBuffer(data: sampleData,
                                                              formatDescription: description,
                                                              presentationTime: presentationTime) else {
            NSLog("[Tandem] could not build a sample buffer")
            recordDropped(now: started)
            requestKeyframe(now: started)
            return
        }

        // Never let the layer build a backlog: this is a live stream, latency
        // beats completeness.
        if isReadyForMoreMediaData() {
            inFlight = 0
        } else {
            inFlight += 1
        }
        if inFlight > 2 {
            flushLayer()
            inFlight = 0
            recordDropped(now: started)
        }

        enqueueSample(sample)

        let finished = CACurrentMediaTime()
        let queued = inFlight
        var e2eMs: Double?
        if let offset = hostClockOffsetUs {
            let nowHostUs = Int64(monotonicMicros()) + offset
            let delta = nowHostUs - Int64(frame.captureTimestampUs)
            if delta >= 0, delta < 5_000_000 { e2eMs = Double(delta) / 1000.0 }
        }

        statsLock.lock()
        decodedWindow.add(1, now: finished)
        decodeMsWindow.add((finished - started) * 1000.0, now: finished)
        if let e2eMs { e2eMsWindow.add(e2eMs, now: finished) }
        lastQueued = queued
        statsLock.unlock()
    }

    private func recordDropped(now: TimeInterval) {
        statsLock.lock()
        droppedWindow.add(1, now: now)
        statsLock.unlock()
    }

    private func requestKeyframe(now: TimeInterval) {
        // At most one request per 500 ms so a broken stream cannot flood the host.
        guard now - keyframeRequestedAt > Self.keyframeRequestInterval else { return }
        keyframeRequestedAt = now
        onKeyframeNeeded?()
    }

    // MARK: - Layer access (iOS 17 moved these onto AVSampleBufferVideoRenderer)

    private func enqueueSample(_ sample: CMSampleBuffer) {
        if #available(iOS 17.0, *) {
            displayLayer.sampleBufferRenderer.enqueue(sample)
        } else {
            legacyEnqueue(sample)
        }
    }

    private func flushLayer() {
        if #available(iOS 17.0, *) {
            displayLayer.sampleBufferRenderer.flush()
        } else {
            legacyFlush()
        }
    }

    private func isReadyForMoreMediaData() -> Bool {
        if #available(iOS 17.0, *) {
            return displayLayer.sampleBufferRenderer.isReadyForMoreMediaData
        }
        return legacyIsReady()
    }

    private func layerFailure() -> Error? {
        if #available(iOS 17.0, *) {
            return displayLayer.sampleBufferRenderer.status == .failed ? displayLayer.sampleBufferRenderer.error : nil
        }
        return legacyFailure()
    }

    @available(iOS, deprecated: 17.0, message: "iOS 16 fallback for AVSampleBufferVideoRenderer")
    private func legacyEnqueue(_ sample: CMSampleBuffer) { displayLayer.enqueue(sample) }

    @available(iOS, deprecated: 17.0, message: "iOS 16 fallback for AVSampleBufferVideoRenderer")
    private func legacyFlush() { displayLayer.flush() }

    @available(iOS, deprecated: 17.0, message: "iOS 16 fallback for AVSampleBufferVideoRenderer")
    private func legacyIsReady() -> Bool { displayLayer.isReadyForMoreMediaData }

    @available(iOS, deprecated: 17.0, message: "iOS 16 fallback for AVSampleBufferVideoRenderer")
    private func legacyFailure() -> Error? { displayLayer.status == .failed ? displayLayer.error : nil }
}
