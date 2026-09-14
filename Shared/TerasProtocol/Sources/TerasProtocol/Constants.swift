import Foundation

/// Constants shared by every Teras peer. See docs/PROTOCOL.md.
public enum Teras {
    public static let protocolVersion = 1
    public static let port: UInt16 = 41777
    public static let bonjourServiceType = "_teras._tcp"
    /// Maximum `length` field value (bytes after the length prefix).
    public static let maxFrameLength = 16 * 1024 * 1024
    public static let pingInterval: TimeInterval = 1.0
    public static let pongTimeout: TimeInterval = 3.0
    public static let statsInterval: TimeInterval = 1.0
    public static let pairMaxAttempts = 3
}

public enum FrameType: UInt8, Sendable {
    case hello = 0x01
    case helloAck = 0x02
    case pairRequired = 0x03
    case pair = 0x04
    case pairOK = 0x05
    case pairFail = 0x06
    case auth = 0x07
    case authOK = 0x08
    case authFail = 0x09
    case streamConfig = 0x10
    case ready = 0x11
    case video = 0x12
    case keyframeRequest = 0x13
    case deviceConfig = 0x14
    case touch = 0x20
    case scroll = 0x21
    case key = 0x22
    case pointer = 0x23
    case ping = 0x30
    case pong = 0x31
    case stats = 0x32
    case bye = 0x40
    case enc = 0x7F
}
