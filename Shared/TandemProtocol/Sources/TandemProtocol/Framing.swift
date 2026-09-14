import Foundation

/// One wire frame: `[u32 length][u8 type][payload]` where length = 1 + payload.count.
public struct Frame: Equatable, Sendable {
    public var type: FrameType
    public var payload: Data

    public init(type: FrameType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    /// Serialise for the wire.
    public func encoded() -> Data {
        var out = Data(capacity: 5 + payload.count)
        out.appendUInt32(UInt32(1 + payload.count))
        out.append(type.rawValue)
        out.append(payload)
        return out
    }
}

public enum FramingError: Error, Equatable {
    case badLength(UInt32)
    case unknownType(UInt8)
}

/// Incremental parser. Feed arbitrary byte chunks; pull complete frames.
/// Unknown frame types are skipped (PROTOCOL §9) and reported via `skippedUnknown`.
public struct FrameParser {
    private var buffer = Data()
    public private(set) var skippedUnknown = 0

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete frame or nil if more bytes are needed.
    /// Throws on a protocol violation; the caller MUST close the connection.
    public mutating func next() throws -> Frame? {
        while true {
            guard buffer.count >= 4 else { return nil }
            let length = buffer.readUInt32(at: buffer.startIndex)
            guard length >= 1, Int(length) <= Tandem.maxFrameLength else {
                throw FramingError.badLength(length)
            }
            let total = 4 + Int(length)
            guard buffer.count >= total else { return nil }
            let typeByte = buffer[buffer.startIndex + 4]
            let payload = buffer.subdata(in: (buffer.startIndex + 5)..<(buffer.startIndex + total))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + total))
            if buffer.isEmpty { buffer = Data() } // release storage
            if let type = FrameType(rawValue: typeByte) {
                return Frame(type: type, payload: payload)
            }
            skippedUnknown += 1
            // loop: skip unknown frame
        }
    }
}

// MARK: - Big-endian helpers

extension Data {
    mutating func appendUInt8(_ v: UInt8) { append(v) }
    mutating func appendUInt32(_ v: UInt32) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
    mutating func appendUInt64(_ v: UInt64) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
    mutating func appendFloat32(_ v: Float) {
        appendUInt32(v.bitPattern)
    }
    func readUInt32(at index: Data.Index) -> UInt32 {
        var v: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &v) { dst in
            copyBytes(to: dst.bindMemory(to: UInt8.self), from: index..<(index + 4))
        }
        return UInt32(bigEndian: v)
    }
    func readUInt64(at index: Data.Index) -> UInt64 {
        var v: UInt64 = 0
        _ = Swift.withUnsafeMutableBytes(of: &v) { dst in
            copyBytes(to: dst.bindMemory(to: UInt8.self), from: index..<(index + 8))
        }
        return UInt64(bigEndian: v)
    }
    func readFloat32(at index: Data.Index) -> Float {
        Float(bitPattern: readUInt32(at: index))
    }
}

/// Sequential big-endian reader over a Data payload.
public struct ByteReader {
    private let data: Data
    private var offset: Data.Index
    public init(_ data: Data) { self.data = data; self.offset = data.startIndex }
    public var remaining: Int { data.endIndex - offset }
    public var isAtEnd: Bool { remaining == 0 }
    public mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw BinaryError.truncated }
        defer { offset += 1 }
        return data[offset]
    }
    public mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw BinaryError.truncated }
        defer { offset += 4 }
        return data.readUInt32(at: offset)
    }
    public mutating func u64() throws -> UInt64 {
        guard remaining >= 8 else { throw BinaryError.truncated }
        defer { offset += 8 }
        return data.readUInt64(at: offset)
    }
    public mutating func f32() throws -> Float {
        Float(bitPattern: try u32())
    }
    public mutating func bytes(_ n: Int) throws -> Data {
        guard remaining >= n else { throw BinaryError.truncated }
        defer { offset += n }
        return data.subdata(in: offset..<(offset + n))
    }
    public mutating func rest() -> Data {
        defer { offset = data.endIndex }
        return data.subdata(in: offset..<data.endIndex)
    }
}

public enum BinaryError: Error, Equatable {
    case truncated
    case invalidValue(String)
}
