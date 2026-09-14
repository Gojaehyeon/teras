import Foundation
import XCTest
import TandemProtocol
@testable import TandemReceiver

extension Data {
    init?(hexString: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex) ?? hexString.endIndex
            guard next > index, let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

/// Interop vectors from docs/VECTORS.md.
enum Vectors {
    static let pin = "123456"
    static let hostId = "11111111-1111-1111-1111-111111111111"
    static let deviceId = "22222222-2222-2222-2222-222222222222"
    static let hostNonce = Data(repeating: 0x01, count: 16)
    static let deviceNonce = Data(repeating: 0x02, count: 16)
    static let secret = Data(repeating: 0x03, count: 32)

    static let pinKey = Data(hexString: "3331a1a8f74fce2199865a288920415bdc45ec25f0cea4de51de6fb64ec86f7a")!
    static let pairProof = Data(hexString: "110062869395c85646afbcf6e8de85c902b69c610c2d469d7fa471763d59d690")!
    static let authProof = Data(hexString: "d68dfc86e14f407a12db80aa5d552db1c3085d01aa2964a0cfa6dcb6c788f76f")!
    static let authAckProof = Data(hexString: "a72b55ef64bc87c44e8a798addb5ba7600e9491d8275c47166fd47fddaf28bce")!
    static let pairBox = Data(hexString: "c90c53edfb1a4127670fe4f4251631623bf295b96611fcc312263d578adb638f39d25d6dc150588a33b15bf4b7171304")!
    static let keyH2R = Data(hexString: "91fbd9ebfbf64bd6d184081001ec015052beb69813a66c16df6880d7723f2cd6")!
    static let keyR2H = Data(hexString: "42c14ebc49d6125a587031486fc377723ccb7869b44fa63950e53867ef15782c")!
}

/// A `FrameChannel` that records everything instead of touching a socket.
final class FakeChannel: FrameChannel {
    var linkTransport: Transport
    private(set) var sent: [Frame] = []
    private(set) var closeReasons: [String?] = []
    private(set) var isClosed = false
    private(set) var encryptionKeys: (h2r: Data, r2h: Data)?
    var clockOffsetUs: Int64?
    var roundTripMs: Double = 0

    init(linkTransport: Transport) {
        self.linkTransport = linkTransport
    }

    func send(_ frame: Frame) { sent.append(frame) }

    func enableEncryption(hostToReceiver: Data, receiverToHost: Data) {
        encryptionKeys = (hostToReceiver, receiverToHost)
    }

    func close(reason: String?) {
        isClosed = true
        closeReasons.append(reason)
    }

    func frames(ofType type: FrameType) -> [Frame] { sent.filter { $0.type == type } }
    func firstFrame(ofType type: FrameType) -> Frame? { sent.first { $0.type == type } }
    var types: [FrameType] { sent.map(\.type) }
}

final class FakeVideoSink: VideoSink {
    private(set) var configurations: [StreamConfig] = []
    private(set) var frames: [VideoFrame] = []
    private(set) var resetCount = 0
    var stats = VideoStatsSnapshot()

    func configure(_ config: StreamConfig) { configurations.append(config) }
    func enqueue(_ frame: VideoFrame, hostClockOffsetUs: Int64?) { frames.append(frame) }
    func reset() { resetCount += 1 }
    func snapshotStats() -> VideoStatsSnapshot { stats }
}

final class RecordingSessionDelegate: ReceiverSessionDelegate {
    private(set) var states: [ReceiverSession.State] = []
    private(set) var configs: [StreamConfig] = []
    private(set) var pairingFailures: [Int] = []
    private(set) var endReasons: [String] = []

    func session(_ session: ReceiverSession, didChangeState state: ReceiverSession.State) { states.append(state) }
    func session(_ session: ReceiverSession, didConfigureStream config: StreamConfig) { configs.append(config) }
    func session(_ session: ReceiverSession, pairingFailedWithAttemptsLeft attemptsLeft: Int) {
        pairingFailures.append(attemptsLeft)
    }
    func sessionDidEnd(_ session: ReceiverSession, reason: String) { endReasons.append(reason) }
}

enum Fixtures {
    static func descriptor(deviceId: String = Vectors.deviceId,
                           name: String = "Test iPhone",
                           orientation: Orientation = .portrait) -> DeviceDescriptor {
        DeviceDescriptor(deviceId: deviceId,
                         deviceName: name,
                         model: "iPhone16,1",
                         screen: ScreenInfo(wPx: 1179, hPx: 2556, scale: 3, refreshHz: 120,
                                            safeInsets: SafeInsets(top: 177, bottom: 102, left: 0, right: 0)),
                         orientation: orientation,
                         codecs: [.hevc, .h264],
                         maxDecode: Size(w: 4096, h: 2304),
                         features: ["touch", "pencil", "keyboard", "scroll", "hover"])
    }

    static func hello(transport: Transport,
                      encrypt: Bool = false,
                      hostId: String = Vectors.hostId,
                      hostNonce: Data = Vectors.hostNonce) -> Frame {
        let hello = Hello(hostId: hostId,
                          hostName: "Test MacBook Pro",
                          transport: transport,
                          hostNonce: hostNonce,
                          encrypt: encrypt,
                          app: AppInfo(name: "Tandem", version: "1.0.0", build: 1))
        return try! Frame.json(.hello, hello)
    }

    static func streamConfig(codec: Codec = .hevc, w: Int = 2556, h: Int = 1179) -> Frame {
        let config = StreamConfig(codec: codec, wPx: w, hPx: h, fps: 60,
                                  desktop: Size(w: 1278, h: 589), orientation: .landscapeLeft)
        return try! Frame.json(.streamConfig, config)
    }

    /// A session wired to a fake channel with fully deterministic crypto.
    static func makeSession(channel: FakeChannel,
                            store: PairingStoring = MemoryPairingStore(),
                            pin: String = Vectors.pin,
                            secret: Data = Vectors.secret,
                            deviceNonce: Data = Vectors.deviceNonce,
                            descriptor: DeviceDescriptor = Fixtures.descriptor())
        -> (ReceiverSession, RecordingSessionDelegate, FakeVideoSink) {
        let configuration = ReceiverSession.Configuration(
            descriptorProvider: { descriptor },
            pairingStore: store,
            pinGenerator: { pin },
            secretGenerator: { secret },
            nonceGenerator: { deviceNonce })
        let session = ReceiverSession(channel: channel, configuration: configuration)
        let delegate = RecordingSessionDelegate()
        let sink = FakeVideoSink()
        session.delegate = delegate
        session.videoSink = sink
        return (session, delegate, sink)
    }
}
