import Foundation

// JSON control messages. All are additive: unknown keys are ignored by Codable.

public enum Transport: String, Codable, Sendable { case usb, lan }
public enum Platform: String, Codable, Sendable { case ios, android, macos }
public enum Codec: String, Codable, Sendable { case hevc, h264 }
public enum DisplayMode: String, Codable, Sendable { case extend, mirror }

public enum Orientation: String, Codable, Sendable {
    case portrait, landscapeLeft, landscapeRight, portraitUpsideDown
    public var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }
}

public struct SafeInsets: Codable, Equatable, Sendable {
    public var top: Double, bottom: Double, left: Double, right: Double
    public init(top: Double = 0, bottom: Double = 0, left: Double = 0, right: Double = 0) {
        self.top = top; self.bottom = bottom; self.left = left; self.right = right
    }
}

public struct ScreenInfo: Codable, Equatable, Sendable {
    /// Usable full-screen size in physical pixels in the *current* orientation.
    public var wPx: Int
    public var hPx: Int
    public var scale: Double
    public var refreshHz: Double
    public var safeInsets: SafeInsets?
    public init(wPx: Int, hPx: Int, scale: Double, refreshHz: Double, safeInsets: SafeInsets? = nil) {
        self.wPx = wPx; self.hPx = hPx; self.scale = scale; self.refreshHz = refreshHz; self.safeInsets = safeInsets
    }
}

public struct AppInfo: Codable, Equatable, Sendable {
    public var name: String
    public var version: String
    public var build: Int
    public init(name: String, version: String, build: Int) {
        self.name = name; self.version = version; self.build = build
    }
}

public struct Hello: Codable, Equatable, Sendable {
    public var pv: Int
    public var hostId: String
    public var hostName: String
    public var transport: Transport
    public var hostNonce: Data          // base64 in JSON
    public var encrypt: Bool
    public var app: AppInfo?
    public init(pv: Int = Tandem.protocolVersion, hostId: String, hostName: String, transport: Transport,
                hostNonce: Data, encrypt: Bool, app: AppInfo? = nil) {
        self.pv = pv; self.hostId = hostId; self.hostName = hostName; self.transport = transport
        self.hostNonce = hostNonce; self.encrypt = encrypt; self.app = app
    }
}

public struct HelloAck: Codable, Equatable, Sendable {
    public var pv: Int
    public var deviceId: String
    public var deviceName: String
    public var platform: Platform
    public var model: String?
    public var deviceNonce: Data
    public var screen: ScreenInfo
    public var orientation: Orientation
    public var codecs: [Codec]
    public var maxDecode: Size?
    public var features: [String]
    public var paired: Bool
    public var authRequired: Bool
    public init(pv: Int = Tandem.protocolVersion, deviceId: String, deviceName: String, platform: Platform,
                model: String? = nil, deviceNonce: Data, screen: ScreenInfo, orientation: Orientation,
                codecs: [Codec], maxDecode: Size? = nil, features: [String], paired: Bool, authRequired: Bool) {
        self.pv = pv; self.deviceId = deviceId; self.deviceName = deviceName; self.platform = platform
        self.model = model; self.deviceNonce = deviceNonce; self.screen = screen; self.orientation = orientation
        self.codecs = codecs; self.maxDecode = maxDecode; self.features = features
        self.paired = paired; self.authRequired = authRequired
    }
}

public struct Size: Codable, Equatable, Sendable {
    public var w: Int, h: Int
    public init(w: Int, h: Int) { self.w = w; self.h = h }
}

public struct PairRequired: Codable, Equatable, Sendable {
    public var attemptsLeft: Int
    public init(attemptsLeft: Int) { self.attemptsLeft = attemptsLeft }
}
public struct PairMessage: Codable, Equatable, Sendable {
    public var proof: Data
    public init(proof: Data) { self.proof = proof }
}
public struct PairOK: Codable, Equatable, Sendable {
    public var box: Data
    public init(box: Data) { self.box = box }
}
public struct PairFail: Codable, Equatable, Sendable {
    public var attemptsLeft: Int
    public var locked: Bool
    public init(attemptsLeft: Int, locked: Bool) { self.attemptsLeft = attemptsLeft; self.locked = locked }
}
public struct AuthMessage: Codable, Equatable, Sendable {
    public var proof: Data
    public init(proof: Data) { self.proof = proof }
}
public struct AuthOK: Codable, Equatable, Sendable {
    public var proof: Data
    public init(proof: Data) { self.proof = proof }
}
public struct AuthFail: Codable, Equatable, Sendable {
    public var reason: String
    public init(reason: String) { self.reason = reason }
}

public struct StreamConfig: Codable, Equatable, Sendable {
    public var codec: Codec
    public var wPx: Int
    public var hPx: Int
    public var fps: Int
    public var desktop: Size
    public var orientation: Orientation
    public var mode: DisplayMode
    public var cursorBaked: Bool
    public init(codec: Codec, wPx: Int, hPx: Int, fps: Int, desktop: Size, orientation: Orientation,
                mode: DisplayMode = .extend, cursorBaked: Bool = true) {
        self.codec = codec; self.wPx = wPx; self.hPx = hPx; self.fps = fps; self.desktop = desktop
        self.orientation = orientation; self.mode = mode; self.cursorBaked = cursorBaked
    }
}

public struct DeviceConfig: Codable, Equatable, Sendable {
    public var orientation: Orientation
    public var screen: ScreenInfo
    public init(orientation: Orientation, screen: ScreenInfo) { self.orientation = orientation; self.screen = screen }
}

public struct KeyEvent: Codable, Equatable, Sendable {
    public var down: Bool
    public var keyCode: Int
    public var text: String?
    public var mods: [String]
    public init(down: Bool, keyCode: Int, text: String?, mods: [String] = []) {
        self.down = down; self.keyCode = keyCode; self.text = text; self.mods = mods
    }
}

public struct Stats: Codable, Equatable, Sendable {
    public var fpsDecoded: Double
    public var fpsDropped: Double
    public var decodeMsP50: Double
    public var queued: Int
    public var rttMs: Double
    public var e2eMsP50: Double?
    public init(fpsDecoded: Double, fpsDropped: Double, decodeMsP50: Double, queued: Int, rttMs: Double, e2eMsP50: Double? = nil) {
        self.fpsDecoded = fpsDecoded; self.fpsDropped = fpsDropped; self.decodeMsP50 = decodeMsP50
        self.queued = queued; self.rttMs = rttMs; self.e2eMsP50 = e2eMsP50
    }
}

public struct Bye: Codable, Equatable, Sendable {
    public var reason: String
    public init(reason: String) { self.reason = reason }
}

// MARK: - JSON coding

public enum JSONCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dataEncodingStrategy = .base64
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dataDecodingStrategy = .base64
        return d
    }()
}

public extension Frame {
    /// Build a JSON frame.
    static func json<T: Encodable>(_ type: FrameType, _ value: T) throws -> Frame {
        Frame(type: type, payload: try JSONCoding.encoder.encode(value))
    }
    /// Decode a JSON payload.
    func decode<T: Decodable>(_ t: T.Type = T.self) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: payload)
    }
}
