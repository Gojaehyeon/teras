import Foundation

// Binary hot-path messages (PROTOCOL §4, §6, §7).

public struct VideoFrame: Equatable, Sendable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let keyframe = Flags(rawValue: 1 << 0)
        public static let hasParameterSets = Flags(rawValue: 1 << 1)
        public static let discontinuity = Flags(rawValue: 1 << 2)
    }
    public var flags: Flags
    public var captureTimestampUs: UInt64
    public var seq: UInt32
    public var annexB: Data

    public init(flags: Flags, captureTimestampUs: UInt64, seq: UInt32, annexB: Data) {
        self.flags = flags; self.captureTimestampUs = captureTimestampUs; self.seq = seq; self.annexB = annexB
    }

    public func frame() -> Frame {
        var p = Data(capacity: 13 + annexB.count)
        p.append(flags.rawValue)
        p.appendUInt64(captureTimestampUs)
        p.appendUInt32(seq)
        p.append(annexB)
        return Frame(type: .video, payload: p)
    }

    public init(parsing payload: Data) throws {
        var r = ByteReader(payload)
        flags = Flags(rawValue: try r.u8())
        captureTimestampUs = try r.u64()
        seq = try r.u32()
        annexB = r.rest()
    }
}

public enum TouchPhase: UInt8, Sendable { case began = 0, moved = 1, ended = 2, cancelled = 3 }
public enum TouchTool: UInt8, Sendable { case finger = 0, stylus = 1 }

public struct TouchPointer: Equatable, Sendable {
    public var id: UInt32
    public var tool: TouchTool
    public var x: Float, y: Float          // normalized over the video frame
    public var pressure: Float
    public var tiltX: Float, tiltY: Float
    public var azimuth: Float
    public init(id: UInt32, tool: TouchTool, x: Float, y: Float, pressure: Float = 1,
                tiltX: Float = 0, tiltY: Float = 0, azimuth: Float = 0) {
        self.id = id; self.tool = tool; self.x = x; self.y = y; self.pressure = pressure
        self.tiltX = tiltX; self.tiltY = tiltY; self.azimuth = azimuth
    }
}

public struct TouchEvent: Equatable, Sendable {
    public var phase: TouchPhase
    public var pointers: [TouchPointer]
    public init(phase: TouchPhase, pointers: [TouchPointer]) { self.phase = phase; self.pointers = pointers }

    public func frame() -> Frame {
        var p = Data(capacity: 2 + pointers.count * 29)
        p.append(phase.rawValue)
        p.append(UInt8(pointers.count))
        for t in pointers {
            p.appendUInt32(t.id); p.append(t.tool.rawValue)
            p.appendFloat32(t.x); p.appendFloat32(t.y); p.appendFloat32(t.pressure)
            p.appendFloat32(t.tiltX); p.appendFloat32(t.tiltY); p.appendFloat32(t.azimuth)
        }
        return Frame(type: .touch, payload: p)
    }

    public init(parsing payload: Data) throws {
        var r = ByteReader(payload)
        guard let ph = TouchPhase(rawValue: try r.u8()) else { throw BinaryError.invalidValue("phase") }
        phase = ph
        let n = Int(try r.u8())
        var ps: [TouchPointer] = []
        ps.reserveCapacity(n)
        for _ in 0..<n {
            let id = try r.u32()
            guard let tool = TouchTool(rawValue: try r.u8()) else { throw BinaryError.invalidValue("tool") }
            ps.append(TouchPointer(id: id, tool: tool, x: try r.f32(), y: try r.f32(), pressure: try r.f32(),
                                   tiltX: try r.f32(), tiltY: try r.f32(), azimuth: try r.f32()))
        }
        pointers = ps
    }
}

public enum ScrollPhase: UInt8, Sendable { case began = 0, changed = 1, ended = 2 }

public struct ScrollEvent: Equatable, Sendable {
    public var x: Float, y: Float          // normalized position
    public var dx: Float, dy: Float        // points
    public var phase: ScrollPhase
    public init(x: Float, y: Float, dx: Float, dy: Float, phase: ScrollPhase) {
        self.x = x; self.y = y; self.dx = dx; self.dy = dy; self.phase = phase
    }
    public func frame() -> Frame {
        var p = Data(capacity: 17)
        p.appendFloat32(x); p.appendFloat32(y); p.appendFloat32(dx); p.appendFloat32(dy); p.append(phase.rawValue)
        return Frame(type: .scroll, payload: p)
    }
    public init(parsing payload: Data) throws {
        var r = ByteReader(payload)
        x = try r.f32(); y = try r.f32(); dx = try r.f32(); dy = try r.f32()
        guard let ph = ScrollPhase(rawValue: try r.u8()) else { throw BinaryError.invalidValue("phase") }
        phase = ph
    }
}

public enum PointerKind: UInt8, Sendable { case move = 0, down = 1, up = 2 }
public enum PointerButton: UInt8, Sendable { case left = 0, right = 1, middle = 2 }

public struct PointerEvent: Equatable, Sendable {
    public var kind: PointerKind
    public var button: PointerButton
    public var x: Float, y: Float
    public init(kind: PointerKind, button: PointerButton, x: Float, y: Float) {
        self.kind = kind; self.button = button; self.x = x; self.y = y
    }
    public func frame() -> Frame {
        var p = Data(capacity: 10)
        p.append(kind.rawValue); p.append(button.rawValue); p.appendFloat32(x); p.appendFloat32(y)
        return Frame(type: .pointer, payload: p)
    }
    public init(parsing payload: Data) throws {
        var r = ByteReader(payload)
        guard let k = PointerKind(rawValue: try r.u8()) else { throw BinaryError.invalidValue("kind") }
        guard let b = PointerButton(rawValue: try r.u8()) else { throw BinaryError.invalidValue("button") }
        kind = k; button = b; x = try r.f32(); y = try r.f32()
    }
}

public struct Ping: Equatable, Sendable {
    public var sentUs: UInt64
    public init(sentUs: UInt64) { self.sentUs = sentUs }
    public func frame() -> Frame {
        var p = Data(capacity: 8); p.appendUInt64(sentUs)
        return Frame(type: .ping, payload: p)
    }
    public init(parsing payload: Data) throws {
        var r = ByteReader(payload); sentUs = try r.u64()
    }
}

public struct Pong: Equatable, Sendable {
    public var echoUs: UInt64
    public var receivedUs: UInt64
    public init(echoUs: UInt64, receivedUs: UInt64) { self.echoUs = echoUs; self.receivedUs = receivedUs }
    public func frame() -> Frame {
        var p = Data(capacity: 16); p.appendUInt64(echoUs); p.appendUInt64(receivedUs)
        return Frame(type: .pong, payload: p)
    }
    public init(parsing payload: Data) throws {
        var r = ByteReader(payload); echoUs = try r.u64(); receivedUs = try r.u64()
    }
}

/// Monotonic microseconds, suitable for PING and video timestamps.
public func monotonicMicros() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
    return UInt64(ts.tv_sec) * 1_000_000 + UInt64(ts.tv_nsec) / 1_000
}
