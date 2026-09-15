import CoreGraphics
import Foundation

/// Wire format for the Teras Control channel (docs/CONTROL.md §3–§5).
///
/// Everything here is a pure function over bytes so the framing can be tested
/// without a device, an adb server or a socket.

// MARK: - Message types

enum ControlMessageType: UInt8, Sendable, CaseIterable {
    // Mac → server
    case hello = 0x01
    case pointerMove = 0x10
    case button = 0x11
    case scroll = 0x12
    case key = 0x20
    case text = 0x21
    case getDisplay = 0x30
    case setPointerVisible = 0x31
    case ping = 0x32
    case bye = 0x40
    // server → Mac
    case displayInfo = 0x80
    case error = 0x81
    case pong = 0x82
    case ready = 0x8F
}

/// Mouse buttons, in the numbering CONTROL.md §4 gives for BUTTON.
enum ControlButton: UInt8, Sendable, Equatable {
    case left = 0
    case right = 1
    case middle = 2
}

/// The phone's screen as the server currently sees it (CONTROL.md §5).
struct ControlDisplayInfo: Equatable, Sendable {
    var width: Int
    var height: Int
    /// 0–3, quarter turns.
    var rotation: Int
    /// Android's density *scale factor*, `logicalDensityDpi / 160`, not a dpi
    /// figure: a 360 dpi phone reports 2.25. Verified on an SM-F971N.
    /// Nothing in the pointer mapping uses it; `width` and `height` are
    /// already logical pixels, which is what POINTER_MOVE expects.
    var density: Double

    /// The same figure as dots per inch, for anyone who needs real units.
    var dpi: Double { density * 160 }

    var size: CGSize { CGSize(width: CGFloat(width), height: CGFloat(height)) }
}

/// A decoded message from the server.
enum ControlInbound: Equatable, Sendable {
    case displayInfo(ControlDisplayInfo)
    case error(String)
    case pong(UInt64)
    case ready(apiLevel: Int, injectionWorks: Bool)
    /// A type this version of the host does not know. Kept rather than dropped
    /// so a newer server can add messages without breaking the parser.
    case unknown(type: UInt8, payload: Data)
}

enum ControlProtocolError: Error, Equatable {
    case payloadTooLarge(Int)
    case truncated(type: UInt8, expected: Int, got: Int)
    case invalidUTF8(type: UInt8)
    case zeroLengthFrame
}

// MARK: - Encoding

enum ControlProtocol {
    static let version: UInt8 = 1

    /// `length` counts the type byte, so the biggest payload is 65534 bytes.
    static let maxPayload = 65_534

    /// `[u16 length][u8 type][payload]`, big-endian.
    static func frame(_ type: ControlMessageType, payload: Data = Data()) throws -> Data {
        guard payload.count <= maxPayload else { throw ControlProtocolError.payloadTooLarge(payload.count) }
        var data = Data(capacity: payload.count + 3)
        data.appendBigEndian(UInt16(payload.count + 1))
        data.append(type.rawValue)
        data.append(payload)
        return data
    }

    static func hello() -> Data {
        // Fixed-size payloads can never exceed the limit, so the throw is moot.
        (try? frame(.hello, payload: Data([version]))) ?? Data()
    }

    static func pointerMove(x: Float, y: Float) -> Data {
        var payload = Data(capacity: 8)
        payload.appendBigEndian(x)
        payload.appendBigEndian(y)
        return (try? frame(.pointerMove, payload: payload)) ?? Data()
    }

    static func button(_ button: ControlButton, down: Bool, x: Float, y: Float) -> Data {
        var payload = Data(capacity: 10)
        payload.append(button.rawValue)
        payload.append(down ? 1 : 0)
        payload.appendBigEndian(x)
        payload.appendBigEndian(y)
        return (try? frame(.button, payload: payload)) ?? Data()
    }

    static func scroll(x: Float, y: Float, horizontal: Float, vertical: Float) -> Data {
        var payload = Data(capacity: 16)
        payload.appendBigEndian(x)
        payload.appendBigEndian(y)
        payload.appendBigEndian(horizontal)
        payload.appendBigEndian(vertical)
        return (try? frame(.scroll, payload: payload)) ?? Data()
    }

    static func key(down: Bool, keyCode: UInt32, metaState: UInt32, repeatCount: UInt32 = 0) -> Data {
        var payload = Data(capacity: 13)
        payload.append(down ? 1 : 0)
        payload.appendBigEndian(keyCode)
        payload.appendBigEndian(metaState)
        payload.appendBigEndian(repeatCount)
        return (try? frame(.key, payload: payload)) ?? Data()
    }

    /// UTF-8 text typed through `KeyCharacterMap.VIRTUAL_KEYBOARD`.
    /// Text longer than one frame is split by the caller via `textFrames`.
    static func text(_ string: String) throws -> Data {
        try frame(.text, payload: Data(string.utf8))
    }

    /// Split a long string into frames that each fit the 64 KiB limit, never
    /// cutting a UTF-8 sequence in half.
    static func textFrames(_ string: String) -> [Data] {
        let bytes = Data(string.utf8)
        guard bytes.count > maxPayload else {
            return bytes.isEmpty ? [] : [(try? frame(.text, payload: bytes)) ?? Data()]
        }
        var frames: [Data] = []
        var chunk = Data()
        for scalar in string.unicodeScalars {
            let encoded = Data(String(scalar).utf8)
            if chunk.count + encoded.count > maxPayload {
                frames.append((try? frame(.text, payload: chunk)) ?? Data())
                chunk = Data()
            }
            chunk.append(encoded)
        }
        if !chunk.isEmpty { frames.append((try? frame(.text, payload: chunk)) ?? Data()) }
        return frames
    }

    static func getDisplay() -> Data {
        (try? frame(.getDisplay)) ?? Data()
    }

    static func setPointerVisible(_ visible: Bool) -> Data {
        (try? frame(.setPointerVisible, payload: Data([visible ? 1 : 0]))) ?? Data()
    }

    static func ping(_ token: UInt64) -> Data {
        var payload = Data(capacity: 8)
        payload.appendBigEndian(token)
        return (try? frame(.ping, payload: payload)) ?? Data()
    }

    static func bye() -> Data {
        (try? frame(.bye)) ?? Data()
    }

    // MARK: - Decoding

    /// Decode one server message from its type byte and payload.
    static func decode(type: UInt8, payload: Data) throws -> ControlInbound {
        switch ControlMessageType(rawValue: type) {
        case .displayInfo:
            guard payload.count >= 13 else {
                throw ControlProtocolError.truncated(type: type, expected: 13, got: payload.count)
            }
            let width = payload.bigEndianUInt32(at: 0)
            let height = payload.bigEndianUInt32(at: 4)
            let rotation = payload[payload.startIndex + 8]
            let density = payload.bigEndianFloat(at: 9)
            return .displayInfo(ControlDisplayInfo(width: Int(width),
                                                   height: Int(height),
                                                   rotation: Int(rotation),
                                                   density: Double(density)))
        case .error:
            guard let message = String(data: payload, encoding: .utf8) else {
                throw ControlProtocolError.invalidUTF8(type: type)
            }
            return .error(message)
        case .pong:
            guard payload.count >= 8 else {
                throw ControlProtocolError.truncated(type: type, expected: 8, got: payload.count)
            }
            return .pong(payload.bigEndianUInt64(at: 0))
        case .ready:
            guard payload.count >= 2 else {
                throw ControlProtocolError.truncated(type: type, expected: 2, got: payload.count)
            }
            let apiLevel = payload[payload.startIndex]
            let flags = payload[payload.startIndex + 1]
            return .ready(apiLevel: Int(apiLevel), injectionWorks: flags & 0x01 != 0)
        default:
            return .unknown(type: type, payload: payload)
        }
    }
}

// MARK: - Streaming parser

/// Reassembles frames from a byte stream. TCP gives no message boundaries, so
/// bytes are buffered until a whole frame is present.
struct ControlFrameParser {
    private var buffer = Data()

    init() {}

    /// Feed received bytes; returns every complete message they finished.
    /// Malformed payloads are reported as `.error` rather than thrown so one
    /// bad frame cannot take the link down.
    mutating func append(_ data: Data) -> [ControlInbound] {
        buffer.append(data)
        var messages: [ControlInbound] = []
        while true {
            guard buffer.count >= 2 else { break }
            let length = Int(buffer.bigEndianUInt16(at: 0))
            guard length >= 1 else {
                // A zero-length frame carries no type byte; the stream is out
                // of sync and cannot be resynchronised. Drop what we have.
                buffer.removeAll(keepingCapacity: true)
                break
            }
            guard buffer.count >= 2 + length else { break }
            let type = buffer[buffer.startIndex + 2]
            let payloadStart = buffer.startIndex + 3
            let payload = Data(buffer[payloadStart..<(buffer.startIndex + 2 + length)])
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + 2 + length))
            do {
                messages.append(try ControlProtocol.decode(type: type, payload: payload))
            } catch {
                messages.append(.error("malformed frame type 0x\(String(type, radix: 16))"))
            }
        }
        return messages
    }

    var pendingByteCount: Int { buffer.count }
}

// MARK: - Big-endian helpers

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func appendBigEndian(_ value: Float) {
        appendBigEndian(value.bitPattern)
    }
}

extension Data {
    func bigEndianUInt16(at offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) << 8 | UInt16(self[base + 1])
    }

    func bigEndianUInt32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        var value: UInt32 = 0
        for index in 0..<4 { value = value << 8 | UInt32(self[base + index]) }
        return value
    }

    func bigEndianUInt64(at offset: Int) -> UInt64 {
        let base = startIndex + offset
        var value: UInt64 = 0
        for index in 0..<8 { value = value << 8 | UInt64(self[base + index]) }
        return value
    }

    func bigEndianFloat(at offset: Int) -> Float {
        Float(bitPattern: bigEndianUInt32(at: offset))
    }
}
