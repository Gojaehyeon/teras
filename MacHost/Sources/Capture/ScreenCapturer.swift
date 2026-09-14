import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import IOKit.pwr_mgt
import IOSurface
@preconcurrency import ScreenCaptureKit
import TandemProtocol
import os

//
//  Adapted from SideScreen (MIT licence) — MacHost/Sources/ScreenCapture.swift:
//  the SCStream configuration, the CGDisplayStream fallback, the wake/sleep
//  restart and the frame-flow monitor.
//  Copyright (c) SideScreen contributors. See THIRD_PARTY_NOTICES.md.
//

enum ScreenCaptureError: LocalizedError {
    case displayNotShareable(CGDirectDisplayID)
    case shareableContentTimedOut
    case fallbackUnavailable

    var errorDescription: String? {
        switch self {
        case .displayNotShareable(let id):
            return "macOS never offered display \(id) for capture. Check Screen Recording permission."
        case .shareableContentTimedOut:
            return "macOS did not answer the request for capturable displays."
        case .fallbackUnavailable:
            return "Neither ScreenCaptureKit nor CGDisplayStream could capture the display."
        }
    }
}

/// Captures one display into NV12 pixel buffers at a fixed frame rate.
///
/// ScreenCaptureKit is the primary path. When it will not start or stops
/// delivering frames (display sleep is the usual cause) capture drops onto
/// CGDisplayStream, and returns to ScreenCaptureKit on the next wake.
@MainActor
final class ScreenCapturer {
    struct Configuration: Equatable {
        var displayID: CGDirectDisplayID
        var width: Int
        var height: Int
        var fps: Int
    }

    private struct FrameState {
        var lastFrameAt: DispatchTime?
        var receivedFirstFrame = false
        var usingFallback = false
    }

    private(set) var configuration: Configuration

    /// Delivered on the capture queue, never on the main thread. Backed by a
    /// lock because the capture callback reads it off the main actor.
    private let frameHandler = LockedBox<((CVPixelBuffer, UInt64) -> Void)?>(nil)
    nonisolated var onFrame: ((CVPixelBuffer, UInt64) -> Void)? {
        get { frameHandler.value }
        set { frameHandler.value = newValue }
    }
    /// "ScreenCaptureKit" or "CGDisplayStream (fallback)".
    var onCaptureMethodChanged: ((String) -> Void)?
    /// Capture failed in a way we cannot recover from on our own.
    var onFatalError: ((Error) -> Void)?

    private let frameState = OSAllocatedUnfairLock(initialState: FrameState())
    private let captureQueue = DispatchQueue(label: "app.tandem.capture", qos: .userInteractive)

    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var streamDelegate: StreamDelegate?
    private var displayStream: CGDisplayStream?

    private var isRunning = false
    private var generation: UInt64 = 0
    private var restartAttempted = false
    private var wakeRestartPending = false
    private var wakeObservers: [NSObjectProtocol] = []
    private var monitorTimer: DispatchSourceTimer?

    private var sleepAssertionID = IOPMAssertionID(0)
    private var holdsSleepAssertion = false

    /// Last delivered buffer, re-encoded as a keepalive when the desktop is
    /// idle and ScreenCaptureKit legitimately stops producing frames.
    private let lastBuffer = LockedBox<CVPixelBuffer?>(nil)

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit {
        let assertionID = sleepAssertionID
        if holdsSleepAssertion {
            IOPMAssertionRelease(assertionID)
        }
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
        restartAttempted = false
        resetFrameState()
        holdDisplaySleepAssertion()
        registerWakeObservers()

        do {
            try await startScreenCaptureKit()
            startFrameMonitor()
        } catch {
            Log.error(.capture, "ScreenCaptureKit could not start: \(error.localizedDescription)")
            try startFallback()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        stopFrameMonitor()
        unregisterWakeObservers()
        releaseDisplaySleepAssertion()

        streamOutput?.onFrame = nil
        let stream = self.stream
        self.stream = nil
        self.streamOutput = nil
        self.streamDelegate = nil
        if let stream {
            Task.detached { try? await stream.stopCapture() }
        }

        stopFallback()
        lastBuffer.value = nil
        resetFrameState()
        Log.info(.capture, "Capture stopped for display \(configuration.displayID)")
    }

    /// Re-deliver the most recent frame. The session uses this to answer a
    /// keyframe request while the desktop is static and no new frames arrive.
    func replayLastFrame() {
        let buffers = lastBuffer
        let handlers = frameHandler
        captureQueue.async {
            guard let buffer = buffers.value, let handler = handlers.value else { return }
            handler(buffer, monotonicMicros())
        }
    }

    // MARK: - ScreenCaptureKit

    private func startScreenCaptureKit() async throws {
        let display = try await shareableDisplay()

        let output = StreamOutput()
        let currentGeneration = generation
        output.onFrame = { [weak self] sampleBuffer in
            self?.handleSampleBuffer(sampleBuffer, generation: currentGeneration)
        }

        let delegate = StreamDelegate()
        delegate.onStopped = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleStreamFailure(error, generation: currentGeneration)
            }
        }

        let configuration = SCStreamConfiguration()
        configuration.width = self.configuration.width
        configuration.height = self.configuration.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, self.configuration.fps)))
        // Video range (16-235) rather than full range: several Android display
        // pipelines apply a limited-range matrix whatever the VUI flag says, so
        // full-range content comes out with clipped highlights there.
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.queueDepth = 4
        configuration.capturesAudio = false
        configuration.scalesToFit = false
        configuration.backgroundColor = .black

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()

        self.stream = stream
        self.streamOutput = output
        self.streamDelegate = delegate
        Log.info(.capture, "ScreenCaptureKit capturing display \(self.configuration.displayID) at "
                 + "\(self.configuration.width)x\(self.configuration.height)@\(self.configuration.fps)")
        onCaptureMethodChanged?("ScreenCaptureKit")
    }

    /// A newly created virtual display takes a moment to show up in
    /// `SCShareableContent`, so poll for it rather than failing the session.
    private func shareableDisplay() async throws -> SCDisplay {
        for attempt in 1...5 {
            do {
                let content = try await shareableContent(timeout: 10)
                if let match = content.displays.first(where: { $0.displayID == configuration.displayID }) {
                    return match
                }
                Log.debug(.capture, "Display \(configuration.displayID) not shareable yet (attempt \(attempt))")
            } catch {
                Log.debug(.capture, "SCShareableContent attempt \(attempt) failed: \(error.localizedDescription)")
            }
            if attempt < 5 {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        throw ScreenCaptureError.displayNotShareable(configuration.displayID)
    }

    /// `SCShareableContent` can hang indefinitely when Screen Recording
    /// permission has been revoked, so it always gets a deadline.
    private func shareableContent(timeout seconds: UInt64) async throws -> SCShareableContent {
        try await withThrowingTaskGroup(of: SCShareableContent.self) { group in
            group.addTask {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw ScreenCaptureError.shareableContentTimedOut
            }
            guard let result = try await group.next() else {
                throw ScreenCaptureError.shareableContentTimedOut
            }
            group.cancelAll()
            return result
        }
    }

    private nonisolated func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, generation: UInt64) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let isFirst = frameState.withLock { state -> Bool in
            state.lastFrameAt = DispatchTime.now()
            guard !state.receivedFirstFrame else { return false }
            state.receivedFirstFrame = true
            return true
        }
        if isFirst {
            Log.debug(.capture, "First frame from ScreenCaptureKit")
        }
        lastBuffer.value = imageBuffer
        frameHandler.value?(imageBuffer, monotonicMicros())
    }

    private func handleStreamFailure(_ error: Error, generation: UInt64) {
        guard isRunning, generation == self.generation else { return }
        Log.error(.capture, "ScreenCaptureKit stopped: \(error.localizedDescription)")
        if restartAttempted {
            try? startFallback()
        } else {
            restart()
        }
    }

    // MARK: - Restart

    private func restart() {
        guard isRunning else { return }
        restartAttempted = true
        generation &+= 1
        let currentGeneration = generation
        resetFrameState()
        stopFrameMonitor()

        let previous = stream
        streamOutput?.onFrame = nil
        stream = nil
        streamOutput = nil
        streamDelegate = nil

        Task { @MainActor in
            if let previous { try? await previous.stopCapture() }
            guard self.isRunning, currentGeneration == self.generation else { return }
            do {
                try await self.startScreenCaptureKit()
                guard self.isRunning, currentGeneration == self.generation else { return }
                self.startFrameMonitor()
            } catch {
                Log.error(.capture, "ScreenCaptureKit restart failed: \(error.localizedDescription)")
                guard self.isRunning, currentGeneration == self.generation else { return }
                try? self.startFallback()
            }
        }
    }

    // MARK: - Frame-flow monitor

    private func startFrameMonitor() {
        stopFrameMonitor()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.checkFrameFlow() }
        }
        timer.resume()
        monitorTimer = timer
    }

    private func stopFrameMonitor() {
        monitorTimer?.cancel()
        monitorTimer = nil
    }

    private func checkFrameFlow() {
        guard isRunning else { return stopFrameMonitor() }
        let snapshot = frameState.withLock { $0 }
        guard !snapshot.usingFallback else { return stopFrameMonitor() }

        let stalled: Bool
        if let last = snapshot.lastFrameAt {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- last.uptimeNanoseconds) / 1_000_000_000
            stalled = elapsed > 5
        } else {
            stalled = true
        }
        guard stalled else { return }

        if snapshot.receivedFirstFrame, lastBuffer.value != nil {
            // The desktop is simply idle: macOS stops producing frames when
            // nothing changes. Re-send the last picture so the receiver's
            // liveness checks and decoder stay happy.
            replayLastFrame()
            frameState.withLock { $0.lastFrameAt = DispatchTime.now() }
            return
        }

        stopFrameMonitor()
        if restartAttempted {
            Log.error(.capture, "No frames after a restart; switching to CGDisplayStream")
            try? startFallback()
        } else {
            Log.info(.capture, "No frames for 5s; restarting ScreenCaptureKit")
            restart()
        }
    }

    // MARK: - CGDisplayStream fallback

    /// CGDisplayStream is deprecated in favour of ScreenCaptureKit, which is
    /// exactly the thing that has failed by the time we get here.
    private func startFallback() throws {
        guard isRunning else { return }
        let alreadyActive = frameState.withLock { state -> Bool in
            guard !state.usingFallback else { return true }
            state.usingFallback = true
            return false
        }
        guard !alreadyActive else { return }

        streamOutput?.onFrame = nil
        let previous = stream
        stream = nil
        streamOutput = nil
        streamDelegate = nil
        if let previous { Task.detached { try? await previous.stopCapture() } }

        let properties = [CGDisplayStream.showCursor as String: true] as CFDictionary
        let created = CGDisplayStream(
            dispatchQueueDisplay: configuration.displayID,
            outputWidth: configuration.width,
            outputHeight: configuration.height,
            pixelFormat: Int32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            properties: properties,
            queue: captureQueue,
            handler: { [weak self] _, _, surface, _ in
                guard let self, let surface else { return }
                var unmanaged: Unmanaged<CVPixelBuffer>?
                let attributes: [String: Any] = [
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
                ]
                guard CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface,
                                                       attributes as CFDictionary, &unmanaged) == kCVReturnSuccess,
                      let buffer = unmanaged?.takeRetainedValue() else { return }
                self.frameState.withLock { $0.lastFrameAt = DispatchTime.now(); $0.receivedFirstFrame = true }
                self.lastBuffer.value = buffer
                self.frameHandler.value?(buffer, monotonicMicros())
            }
        )

        guard let created else {
            frameState.withLock { $0.usingFallback = false }
            let error = ScreenCaptureError.fallbackUnavailable
            onFatalError?(error)
            throw error
        }
        guard created.start() == .success else {
            frameState.withLock { $0.usingFallback = false }
            let error = ScreenCaptureError.fallbackUnavailable
            onFatalError?(error)
            throw error
        }
        displayStream = created
        Log.info(.capture, "CGDisplayStream fallback active for display \(configuration.displayID)")
        onCaptureMethodChanged?("CGDisplayStream (fallback)")
    }

    private func stopFallback() {
        displayStream?.stop()
        displayStream = nil
    }

    // MARK: - Wake handling

    private func registerWakeObservers() {
        guard wakeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWake() }
            }
            wakeObservers.append(token)
        }
    }

    private func unregisterWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        wakeObservers.forEach { center.removeObserver($0) }
        wakeObservers.removeAll()
    }

    /// Display sleep kills the ScreenCaptureKit stream, which pushes us onto the
    /// fallback for the rest of the session. On wake, climb back up.
    private func handleWake() {
        guard isRunning, !wakeRestartPending else { return }
        wakeRestartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.wakeRestartPending = false
                guard self.isRunning else { return }
                if self.frameState.withLock({ $0.usingFallback }) {
                    self.stopFallback()
                    self.frameState.withLock { $0.usingFallback = false }
                }
                Log.info(.capture, "Screens woke; restarting capture")
                self.restart()
                // A wake restart must not spend the one-shot restart budget the
                // stall detector relies on.
                self.restartAttempted = false
            }
        }
    }

    // MARK: - Sleep assertion

    /// Hold the display awake while streaming. The virtual display stops
    /// producing frames when the physical display idle-sleeps, and the
    /// sleep/wake round trip is what strands the cursor on the receiver.
    private func holdDisplaySleepAssertion() {
        guard !holdsSleepAssertion else { return }
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Tandem is streaming to an external display" as CFString,
            &assertionID)
        guard result == kIOReturnSuccess else {
            Log.debug(.capture, "Could not hold a display-sleep assertion (IOReturn \(result))")
            return
        }
        sleepAssertionID = assertionID
        holdsSleepAssertion = true
    }

    private func releaseDisplaySleepAssertion() {
        guard holdsSleepAssertion else { return }
        IOPMAssertionRelease(sleepAssertionID)
        sleepAssertionID = IOPMAssertionID(0)
        holdsSleepAssertion = false
    }

    private func resetFrameState() {
        frameState.withLock { state in
            state.lastFrameAt = nil
            state.receivedFirstFrame = false
        }
    }
}

// MARK: - ScreenCaptureKit plumbing

private final class StreamOutput: NSObject, SCStreamOutput {
    var onFrame: ((CMSampleBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        onFrame?(sampleBuffer)
    }
}

private final class StreamDelegate: NSObject, SCStreamDelegate {
    var onStopped: ((Error) -> Void)?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error)
    }
}


/// A mutex around a value the compiler cannot prove `Sendable`.
///
/// CoreVideo buffers and plain closures are both safe to move between the
/// capture queue and the main actor here; they simply carry no annotation
/// saying so, and the lock is what actually makes the access safe.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
