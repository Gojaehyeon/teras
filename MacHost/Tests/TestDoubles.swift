import CoreGraphics
import Foundation
import TerasProtocol
import XCTest
@testable import TerasCore

/// In-memory `PeerChannel`: records what the session sends and lets a test
/// play the receiver's part.
final class FakePeerChannel: PeerChannel, @unchecked Sendable {
    private(set) var sent: [Frame] = []
    private(set) var videoSent: [Frame] = []
    private(set) var cancelled = false
    private(set) var encryptionKeys: (h2r: Data, r2h: Data)?

    var rttMs: Double = 4.2
    var videoBacklog = 0

    private var onFrame: ((Frame) -> Void)?
    private var onFailure: ((Error) -> Void)?

    func start(onFrame: @escaping (Frame) -> Void, onFailure: @escaping (Error) -> Void) {
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    func send(_ frame: Frame) { sent.append(frame) }
    func sendVideo(_ frame: Frame) { videoSent.append(frame) }
    func enableEncryption(h2r: Data, r2h: Data) { encryptionKeys = (h2r, r2h) }
    func cancel() { cancelled = true }

    // MARK: - Driving the session

    /// Play a frame as if the receiver had sent it.
    func deliver(_ frame: Frame) { onFrame?(frame) }

    func deliver<T: Encodable>(_ type: FrameType, _ value: T) throws {
        deliver(try Frame.json(type, value))
    }

    func fail(_ error: Error) { onFailure?(error) }

    /// The first frame of a type, decoded.
    func firstFrame(_ type: FrameType) -> Frame? {
        sent.first { $0.type == type }
    }

    func decodeFirst<T: Decodable>(_ type: FrameType, as: T.Type = T.self) throws -> T {
        let frame = try XCTUnwrap(firstFrame(type), "no \(type) was sent")
        return try frame.decode(T.self)
    }

    var sentTypes: [FrameType] { sent.map(\.type) }
}

/// Virtual display stand-in: records what was asked for, creates nothing.
@MainActor
final class FakeDisplayHost: VirtualDisplayHosting {
    private(set) var createdSpecs: [VirtualDisplaySpec] = []
    private(set) var createdNames: [String] = []
    private(set) var createdModes: [DisplayMode] = []
    private(set) var destroyCount = 0
    var createError: Error?

    var displayID: CGDirectDisplayID? = 77
    var bounds: CGRect? = CGRect(x: 1512, y: 0, width: 1278, height: 588)

    func create(spec: VirtualDisplaySpec, name: String, mode: DisplayMode) throws {
        if let createError { throw createError }
        createdSpecs.append(spec)
        createdNames.append(name)
        createdModes.append(mode)
    }

    func setMode(_ mode: DisplayMode) throws { createdModes.append(mode) }

    func destroy() {
        destroyCount += 1
        displayID = nil
    }
}

/// Capture/encode stand-in.
@MainActor
final class FakePipeline: VideoPipeline {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var keyframeRequests = 0
    private(set) var replayCount = 0
    private(set) var lastBitrate = 0
    private(set) var lastCodec: Codec?
    private(set) var lastSpec: VirtualDisplaySpec?
    var startError: Error?

    private var onFrame: ((EncodedFrame) -> Void)?

    var captureMethod: String { "Fake" }

    func start(displayID: CGDirectDisplayID,
               spec: VirtualDisplaySpec,
               codec: Codec,
               bitrateBps: Int,
               onFrame: @escaping (EncodedFrame) -> Void) async throws {
        if let startError { throw startError }
        startCount += 1
        lastSpec = spec
        lastCodec = codec
        lastBitrate = bitrateBps
        self.onFrame = onFrame
    }

    func stop() {
        stopCount += 1
        onFrame = nil
    }

    func requestKeyframe() { keyframeRequests += 1 }
    func replayLastFrame() { replayCount += 1 }
    func setBitrate(_ bitrateBps: Int) { lastBitrate = bitrateBps }

    /// Emit an encoded picture as the real encoder would.
    func emit(_ frame: EncodedFrame) { onFrame?(frame) }
}

/// Input sink that only counts.
@MainActor
final class FakeInputSink: InputSink {
    private(set) var touches: [TouchEvent] = []
    private(set) var scrolls: [ScrollEvent] = []
    private(set) var keys: [KeyEvent] = []
    private(set) var pointers: [PointerEvent] = []

    func handle(_ touch: TouchEvent) { touches.append(touch) }
    func handle(_ scroll: ScrollEvent) { scrolls.append(scroll) }
    func handle(_ key: KeyEvent) { keys.append(key) }
    func handle(_ pointer: PointerEvent) { pointers.append(pointer) }
}

// MARK: - Shared fixtures

enum Fixtures {
    /// The identities and nonces from docs/VECTORS.md, so proofs computed in a
    /// test can be compared with the published interop vectors.
    static let hostId = "11111111-1111-1111-1111-111111111111"
    static let deviceId = "22222222-2222-2222-2222-222222222222"
    static let hostNonce = Data(repeating: 0x01, count: 16)
    static let deviceNonce = Data(repeating: 0x02, count: 16)
    static let secret = Data(repeating: 0x03, count: 32)
    static let pin = "123456"

    static func helloAck(authRequired: Bool,
                         paired: Bool = false,
                         codecs: [Codec] = [.hevc, .h264],
                         screen: ScreenInfo = ScreenInfo(wPx: 2556, hPx: 1179, scale: 3, refreshHz: 120),
                         orientation: Orientation = .landscapeLeft,
                         maxDecode: Size? = nil) -> HelloAck {
        HelloAck(deviceId: deviceId,
                 deviceName: "Test iPhone",
                 platform: .ios,
                 model: "iPhone18,1",
                 deviceNonce: deviceNonce,
                 screen: screen,
                 orientation: orientation,
                 codecs: codecs,
                 maxDecode: maxDecode,
                 features: ["touch", "keyboard", "scroll"],
                 paired: paired,
                 authRequired: authRequired)
    }

    static func settingsStore(_ function: String = #function) -> DeviceSettingsStore {
        let suite = "app.teras.tests.\(abs(function.hashValue))"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return DeviceSettingsStore(defaults: defaults)
    }
}

extension Data {
    /// Lowercase hex, for comparing against docs/VECTORS.md.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            guard let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex),
                  let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}

/// Poll until `condition` holds or the deadline passes.
func waitUntil(timeout: TimeInterval = 2,
               file: StaticString = #filePath,
               line: UInt = #line,
               _ description: String,
               _ condition: @escaping @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await MainActor.run(body: condition) { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("timed out waiting for \(description)", file: file, line: line)
}
