import Foundation

/// A device as usbmuxd describes it.
struct UsbmuxDevice: Equatable, Sendable {
    var deviceID: UInt32
    var udid: String
    var connectionType: String
    var productID: Int?

    var isUSB: Bool { connectionType.caseInsensitiveCompare("USB") == .orderedSame }
}

enum UsbmuxResult: Int, Sendable {
    case ok = 0
    case badCommand = 1
    case badDevice = 2
    case connectionRefused = 3

    var message: String {
        switch self {
        case .ok: return "OK"
        case .badCommand: return "usbmuxd rejected the request"
        case .badDevice: return "usbmuxd does not know that device"
        case .connectionRefused: return "the device refused the connection"
        }
    }
}

enum UsbmuxEvent: Equatable, Sendable {
    case result(UsbmuxResult)
    case attached(UsbmuxDevice)
    case detached(UInt32)
}

enum UsbmuxError: LocalizedError, Equatable {
    case badHeader(version: UInt32, type: UInt32)
    case oversizedMessage(UInt32)
    case malformedPayload
    case unexpectedReply(String)
    case failed(UsbmuxResult)
    case timedOut
    case socket(String)

    var errorDescription: String? {
        switch self {
        case .badHeader(let version, let type):
            return "usbmuxd sent an unexpected header (version \(version), type \(type))."
        case .oversizedMessage(let length):
            return "usbmuxd announced a \(length) byte message, which is out of range."
        case .malformedPayload:
            return "usbmuxd sent a property list we could not read."
        case .unexpectedReply(let kind):
            return "usbmuxd replied with \"\(kind)\", which was not expected here."
        case .failed(let result):
            return result.message
        case .timedOut:
            return "usbmuxd did not reply in time."
        case .socket(let detail):
            return "The usbmuxd socket failed: \(detail)."
        }
    }
}

/// Encoding and decoding for the usbmuxd property-list protocol.
///
/// The wire format is public (documented by libimobiledevice): every message is
/// `[u32 LE length including this 16-byte header][u32 LE version = 1]
/// [u32 LE type = 8 (plist)][u32 LE tag][XML property list]`.
///
/// Everything here is a pure function over bytes so it can be unit tested
/// without a socket.
enum UsbmuxProtocol {
    static let socketPath = "/var/run/usbmuxd"
    static let headerSize = 16
    static let versionPlist: UInt32 = 1
    static let typePlist: UInt32 = 8
    static let maxMessageSize = 4 * 1024 * 1024

    static let programName = "Tandem"
    static let clientVersion = "Tandem 1.0"

    /// lockdownd's port on the device; used for `GetValue DeviceName`.
    static let lockdownPort: UInt16 = 62078

    /// usbmuxd wants `PortNumber` in network byte order but carries it in an
    /// integer field, so the value is the byte-swapped port.
    static func networkPort(_ port: UInt16) -> Int {
        Int(port.bigEndian)
    }

    // MARK: - Requests

    static func listDevicesRequest() -> [String: Any] {
        baseRequest(messageType: "ListDevices")
    }

    static func listenRequest() -> [String: Any] {
        baseRequest(messageType: "Listen")
    }

    static func connectRequest(deviceID: UInt32, port: UInt16) -> [String: Any] {
        var request = baseRequest(messageType: "Connect")
        request["DeviceID"] = Int(deviceID)
        request["PortNumber"] = networkPort(port)
        return request
    }

    private static func baseRequest(messageType: String) -> [String: Any] {
        [
            "MessageType": messageType,
            "ProgName": programName,
            "ClientVersionString": clientVersion,
            "kLibUSBMuxVersion": 3,
        ]
    }

    // MARK: - Encoding

    static func encode(_ plist: [String: Any], tag: UInt32) throws -> Data {
        let body: Data
        do {
            body = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        } catch {
            throw UsbmuxError.malformedPayload
        }
        var out = Data(capacity: headerSize + body.count)
        out.appendLittleEndian(UInt32(headerSize + body.count))
        out.appendLittleEndian(versionPlist)
        out.appendLittleEndian(typePlist)
        out.appendLittleEndian(tag)
        out.append(body)
        return out
    }

    // MARK: - Decoding

    /// A decoded usbmuxd message. The payload is a property list of immutable
    /// Foundation values, which is safe to hand between threads even though
    /// `Any` carries no such promise.
    struct Message: @unchecked Sendable {
        var tag: UInt32
        var plist: [String: Any]

        var messageType: String? { plist["MessageType"] as? String }
    }

    /// Take one complete message off the front of `buffer`.
    /// Returns nil when more bytes are needed; throws on a protocol violation.
    static func decode(from buffer: inout Data) throws -> Message? {
        guard buffer.count >= headerSize else { return nil }
        let base = buffer.startIndex
        let length = buffer.readLittleEndianUInt32(at: base)
        guard length >= UInt32(headerSize), length <= UInt32(maxMessageSize) else {
            throw UsbmuxError.oversizedMessage(length)
        }
        guard buffer.count >= Int(length) else { return nil }

        let version = buffer.readLittleEndianUInt32(at: base + 4)
        let type = buffer.readLittleEndianUInt32(at: base + 8)
        let tag = buffer.readLittleEndianUInt32(at: base + 12)
        guard version == versionPlist, type == typePlist else {
            throw UsbmuxError.badHeader(version: version, type: type)
        }

        let body = buffer.subdata(in: (base + headerSize)..<(base + Int(length)))
        buffer.removeSubrange(base..<(base + Int(length)))
        if buffer.isEmpty { buffer = Data() }

        guard let object = try? PropertyListSerialization.propertyList(from: body, options: [], format: nil),
              let plist = object as? [String: Any] else {
            throw UsbmuxError.malformedPayload
        }
        return Message(tag: tag, plist: plist)
    }

    // MARK: - Interpretation

    static func event(from message: Message) -> UsbmuxEvent? {
        switch message.messageType {
        case "Result":
            guard let number = message.plist["Number"] as? Int,
                  let result = UsbmuxResult(rawValue: number) else { return nil }
            return .result(result)
        case "Attached":
            guard let device = device(from: message.plist) else { return nil }
            return .attached(device)
        case "Detached":
            guard let deviceID = message.plist["DeviceID"] as? Int else { return nil }
            return .detached(UInt32(truncatingIfNeeded: deviceID))
        default:
            return nil
        }
    }

    /// Read one device out of an `Attached` event or a `ListDevices` entry.
    static func device(from entry: [String: Any]) -> UsbmuxDevice? {
        guard let deviceID = entry["DeviceID"] as? Int else { return nil }
        let properties = entry["Properties"] as? [String: Any] ?? entry
        guard let udid = properties["SerialNumber"] as? String, !udid.isEmpty else { return nil }
        return UsbmuxDevice(deviceID: UInt32(truncatingIfNeeded: deviceID),
                            udid: udid,
                            connectionType: properties["ConnectionType"] as? String ?? "USB",
                            productID: properties["ProductID"] as? Int)
    }

    /// Devices out of a `ListDevices` reply.
    static func devices(fromListReply plist: [String: Any]) -> [UsbmuxDevice] {
        guard let list = plist["DeviceList"] as? [[String: Any]] else { return [] }
        return list.compactMap { device(from: $0) }
    }

    // MARK: - lockdownd

    /// lockdownd on port 62078 uses a different framing to usbmuxd itself:
    /// `[u32 big-endian length][XML property list]`.
    static func lockdownRequest(_ plist: [String: Any]) throws -> Data {
        let body: Data
        do {
            body = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        } catch {
            throw UsbmuxError.malformedPayload
        }
        var out = Data(capacity: 4 + body.count)
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    static func deviceNameRequest() throws -> Data {
        try lockdownRequest([
            "Request": "GetValue",
            "Key": "DeviceName",
            "Label": programName,
        ])
    }

    static func decodeLockdownReply(from buffer: inout Data) throws -> [String: Any]? {
        guard buffer.count >= 4 else { return nil }
        let base = buffer.startIndex
        var length: UInt32 = 0
        withUnsafeMutableBytes(of: &length) { destination in
            buffer.copyBytes(to: destination.bindMemory(to: UInt8.self), from: base..<(base + 4))
        }
        let bodyLength = Int(UInt32(bigEndian: length))
        guard bodyLength > 0, bodyLength <= maxMessageSize else {
            throw UsbmuxError.oversizedMessage(UInt32(truncatingIfNeeded: bodyLength))
        }
        guard buffer.count >= 4 + bodyLength else { return nil }

        let body = buffer.subdata(in: (base + 4)..<(base + 4 + bodyLength))
        buffer.removeSubrange(base..<(base + 4 + bodyLength))
        if buffer.isEmpty { buffer = Data() }

        guard let object = try? PropertyListSerialization.propertyList(from: body, options: [], format: nil),
              let plist = object as? [String: Any] else {
            throw UsbmuxError.malformedPayload
        }
        return plist
    }

    static func deviceName(fromLockdownReply plist: [String: Any]) -> String? {
        if let value = plist["Value"] as? String, !value.isEmpty { return value }
        return nil
    }
}

// MARK: - Little-endian helpers

extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func readLittleEndianUInt32(at index: Data.Index) -> UInt32 {
        var value: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { destination in
            copyBytes(to: destination.bindMemory(to: UInt8.self), from: index..<(index + 4))
        }
        return UInt32(littleEndian: value)
    }
}
