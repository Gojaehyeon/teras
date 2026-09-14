import XCTest
@testable import TerasProtocol

final class FramingTests: XCTestCase {
    func testRoundTripSplitReads() throws {
        let frames = [Frame(type: .ping, payload: Data([1,2,3])), Frame(type: .ready), Frame(type: .video, payload: Data(repeating: 9, count: 5000))]
        var wire = Data()
        frames.forEach { wire.append($0.encoded()) }
        var parser = FrameParser()
        var out: [Frame] = []
        var i = wire.startIndex
        while i < wire.endIndex {
            let n = min(7, wire.endIndex - i)
            parser.append(wire.subdata(in: i..<(i + n)))
            while let f = try parser.next() { out.append(f) }
            i += n
        }
        XCTAssertEqual(out, frames)
    }

    func testUnknownTypeSkipped() throws {
        var wire = Data(); wire.appendUInt32(3); wire.append(0x66); wire.append(contentsOf: [0, 0])
        wire.append(Frame(type: .ready).encoded())
        var p = FrameParser(); p.append(wire)
        XCTAssertEqual(try p.next(), Frame(type: .ready))
        XCTAssertEqual(p.skippedUnknown, 1)
    }

    func testBadLengthThrows() {
        var wire = Data(); wire.appendUInt32(0); wire.append(0x11)
        var p = FrameParser(); p.append(wire)
        XCTAssertThrowsError(try p.next())
    }

    func testTouchRoundTrip() throws {
        let t = TouchEvent(phase: .moved, pointers: [TouchPointer(id: 7, tool: .stylus, x: 0.25, y: 0.75, pressure: 0.5, tiltX: 0.1, tiltY: -0.1, azimuth: 1.5)])
        XCTAssertEqual(try TouchEvent(parsing: t.frame().payload), t)
    }

    func testVideoRoundTrip() throws {
        let v = VideoFrame(flags: [.keyframe, .hasParameterSets], captureTimestampUs: 123456789, seq: 42, annexB: Data([0,0,0,1,0x40]))
        let parsed = try VideoFrame(parsing: v.frame().payload)
        XCTAssertEqual(parsed, v)
    }

    func testJSONHello() throws {
        let h = Hello(hostId: "h", hostName: "Mac", transport: .usb, hostNonce: Data(repeating: 1, count: 16), encrypt: false)
        let f = try Frame.json(.hello, h)
        let back: Hello = try f.decode()
        XCTAssertEqual(back, h)
        let s = String(data: f.payload, encoding: .utf8)!
        XCTAssertTrue(s.contains("\"hostNonce\":\"AQEBAQEBAQEBAQEBAQEBAQ==\""))
    }
}
