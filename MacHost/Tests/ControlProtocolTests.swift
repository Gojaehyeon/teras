import XCTest
@testable import TerasCore

final class ControlProtocolTests: XCTestCase {

    // MARK: - Framing

    func testFrameLengthCountsTheTypeByte() throws {
        let frame = try ControlProtocol.frame(.pointerMove, payload: Data([1, 2, 3, 4]))
        XCTAssertEqual(frame.count, 7)
        XCTAssertEqual(frame[0], 0)
        XCTAssertEqual(frame[1], 5, "length is 1 + payload")
        XCTAssertEqual(frame[2], ControlMessageType.pointerMove.rawValue)
    }

    func testEmptyPayloadFrameIsThreeBytes() throws {
        let frame = try ControlProtocol.frame(.bye)
        XCTAssertEqual(Array(frame), [0x00, 0x01, 0x40])
    }

    func testOversizedPayloadIsRejected() {
        let payload = Data(repeating: 0, count: ControlProtocol.maxPayload + 1)
        XCTAssertThrowsError(try ControlProtocol.frame(.text, payload: payload)) { error in
            XCTAssertEqual(error as? ControlProtocolError, .payloadTooLarge(payload.count))
        }
    }

    // MARK: - Encoders

    func testHelloCarriesTheVersion() {
        XCTAssertEqual(Array(ControlProtocol.hello()), [0x00, 0x02, 0x01, 0x01])
    }

    func testPointerMoveIsBigEndianFloats() {
        let frame = ControlProtocol.pointerMove(x: 1, y: -2)
        XCTAssertEqual(frame.count, 11)
        let payload = frame.dropFirst(3)
        XCTAssertEqual(Data(payload).bigEndianFloat(at: 0), 1)
        XCTAssertEqual(Data(payload).bigEndianFloat(at: 4), -2)
    }

    func testButtonEncodesButtonAndState() {
        let frame = ControlProtocol.button(.right, down: true, x: 10.5, y: 20.25)
        let payload = Data(frame.dropFirst(3))
        XCTAssertEqual(frame[2], 0x11)
        XCTAssertEqual(payload[0], ControlButton.right.rawValue)
        XCTAssertEqual(payload[1], 1)
        XCTAssertEqual(payload.bigEndianFloat(at: 2), 10.5)
        XCTAssertEqual(payload.bigEndianFloat(at: 6), 20.25)
    }

    func testScrollCarriesFourFloats() {
        let frame = ControlProtocol.scroll(x: 1, y: 2, horizontal: -0.5, vertical: 1.5)
        let payload = Data(frame.dropFirst(3))
        XCTAssertEqual(payload.count, 16)
        XCTAssertEqual(payload.bigEndianFloat(at: 8), -0.5)
        XCTAssertEqual(payload.bigEndianFloat(at: 12), 1.5)
    }

    func testKeyEncodesCodeMetaAndRepeat() {
        let frame = ControlProtocol.key(down: true, keyCode: 29, metaState: 0x1001, repeatCount: 3)
        let payload = Data(frame.dropFirst(3))
        XCTAssertEqual(frame[2], 0x20)
        XCTAssertEqual(payload.count, 13)
        XCTAssertEqual(payload[0], 1)
        XCTAssertEqual(payload.bigEndianUInt32(at: 1), 29)
        XCTAssertEqual(payload.bigEndianUInt32(at: 5), 0x1001)
        XCTAssertEqual(payload.bigEndianUInt32(at: 9), 3)
    }

    func testTextIsUTF8() throws {
        let frame = try ControlProtocol.text("안녕 hi")
        let payload = Data(frame.dropFirst(3))
        XCTAssertEqual(String(data: payload, encoding: .utf8), "안녕 hi")
    }

    func testTextFramesSplitLongStringsWithoutBreakingScalars() {
        let long = String(repeating: "가", count: 30_000)   // 90,000 UTF-8 bytes
        let frames = ControlProtocol.textFrames(long)
        XCTAssertGreaterThan(frames.count, 1)
        var rebuilt = ""
        for frame in frames {
            XCTAssertLessThanOrEqual(frame.count, ControlProtocol.maxPayload + 3)
            let payload = Data(frame.dropFirst(3))
            let piece = String(data: payload, encoding: .utf8)
            XCTAssertNotNil(piece, "every chunk must be valid UTF-8 on its own")
            rebuilt += piece ?? ""
        }
        XCTAssertEqual(rebuilt, long)
    }

    func testSetPointerVisibleAndPing() {
        XCTAssertEqual(Array(ControlProtocol.setPointerVisible(false)), [0x00, 0x02, 0x31, 0x00])
        let ping = ControlProtocol.ping(0x0102_0304_0506_0708)
        XCTAssertEqual(Array(ping.prefix(3)), [0x00, 0x09, 0x32])
        XCTAssertEqual(Data(ping.dropFirst(3)).bigEndianUInt64(at: 0), 0x0102_0304_0506_0708)
    }

    // MARK: - Decoders

    func testDecodeDisplayInfo() throws {
        var payload = Data()
        payload.append(contentsOf: [0x00, 0x00, 0x04, 0x38])   // 1080
        payload.append(contentsOf: [0x00, 0x00, 0x09, 0x60])   // 2400
        payload.append(1)                                      // rotation
        payload.append(contentsOf: withUnsafeBytes(of: Float(2.75).bitPattern.bigEndian) { Array($0) })

        let message = try ControlProtocol.decode(type: 0x80, payload: payload)
        XCTAssertEqual(message, .displayInfo(ControlDisplayInfo(width: 1080, height: 2400, rotation: 1, density: 2.75)))
    }

    /// Values measured on a real SM-F971N by the control-server agent:
    /// a 360 dpi panel reports density 2.25, because the field is Android's
    /// dp scale factor and not a dpi figure.
    func testDecodeDisplayInfoFromARealDevice() throws {
        var payload = Data()
        payload.append(contentsOf: [0x00, 0x00, 0x09, 0x90])   // 2448
        payload.append(contentsOf: [0x00, 0x00, 0x07, 0x38])   // 1848
        payload.append(0)                                      // rotation
        payload.append(contentsOf: withUnsafeBytes(of: Float(2.25).bitPattern.bigEndian) { Array($0) })

        let message = try ControlProtocol.decode(type: 0x80, payload: payload)
        guard case .displayInfo(let info) = message else {
            return XCTFail("expected displayInfo, got \(message)")
        }
        XCTAssertEqual(info.width, 2448)
        XCTAssertEqual(info.height, 1848)
        XCTAssertEqual(info.rotation, 0)
        XCTAssertEqual(info.density, 2.25, accuracy: 0.0001)
        XCTAssertEqual(info.dpi, 360, accuracy: 0.01, "density is a scale factor, dpi is 160x it")
    }

    /// The same panel after a quarter turn, which the server sends unsolicited.
    func testDecodeRotatedDisplayInfo() throws {
        var payload = Data()
        payload.append(contentsOf: [0x00, 0x00, 0x07, 0x38])   // 1848
        payload.append(contentsOf: [0x00, 0x00, 0x09, 0x90])   // 2448
        payload.append(1)                                      // rotation
        payload.append(contentsOf: withUnsafeBytes(of: Float(2.25).bitPattern.bigEndian) { Array($0) })

        XCTAssertEqual(try ControlProtocol.decode(type: 0x80, payload: payload),
                       .displayInfo(ControlDisplayInfo(width: 1848, height: 2448, rotation: 1, density: 2.25)))
    }

    func testDecodeReadyFlags() throws {
        XCTAssertEqual(try ControlProtocol.decode(type: 0x8F, payload: Data([34, 0x01])),
                       .ready(apiLevel: 34, injectionWorks: true))
        XCTAssertEqual(try ControlProtocol.decode(type: 0x8F, payload: Data([30, 0x00])),
                       .ready(apiLevel: 30, injectionWorks: false))
    }

    func testDecodePongAndError() throws {
        XCTAssertEqual(try ControlProtocol.decode(type: 0x82, payload: Data([0, 0, 0, 0, 0, 0, 0, 7])), .pong(7))
        XCTAssertEqual(try ControlProtocol.decode(type: 0x81, payload: Data("nope".utf8)), .error("nope"))
    }

    func testDecodeRejectsTruncatedPayloads() {
        XCTAssertThrowsError(try ControlProtocol.decode(type: 0x80, payload: Data([0, 0, 0, 1])))
        XCTAssertThrowsError(try ControlProtocol.decode(type: 0x82, payload: Data([0, 1])))
        XCTAssertThrowsError(try ControlProtocol.decode(type: 0x8F, payload: Data([30])))
    }

    func testDecodeKeepsUnknownTypes() throws {
        XCTAssertEqual(try ControlProtocol.decode(type: 0xAB, payload: Data([9])),
                       .unknown(type: 0xAB, payload: Data([9])))
    }

    // MARK: - Round trip through the parser

    func testParserReassemblesFramesSplitAcrossReads() throws {
        var payload = Data()
        payload.append(contentsOf: [0x00, 0x00, 0x04, 0x38])
        payload.append(contentsOf: [0x00, 0x00, 0x09, 0x60])
        payload.append(0)
        payload.append(contentsOf: withUnsafeBytes(of: Float(3.0).bitPattern.bigEndian) { Array($0) })
        let displayInfo = try ControlProtocol.frame(.displayInfo, payload: payload)
        let ready = try ControlProtocol.frame(.ready, payload: Data([33, 1]))
        let stream = displayInfo + ready

        var parser = ControlFrameParser()
        var messages: [ControlInbound] = []
        for byte in stream {
            messages += parser.append(Data([byte]))
        }
        XCTAssertEqual(messages, [
            .displayInfo(ControlDisplayInfo(width: 1080, height: 2400, rotation: 0, density: 3.0)),
            .ready(apiLevel: 33, injectionWorks: true),
        ])
        XCTAssertEqual(parser.pendingByteCount, 0)
    }

    func testParserHandlesSeveralFramesInOneRead() throws {
        var parser = ControlFrameParser()
        let stream = try ControlProtocol.frame(.pong, payload: Data([0, 0, 0, 0, 0, 0, 0, 1]))
            + ControlProtocol.frame(.error, payload: Data("boom".utf8))
        XCTAssertEqual(parser.append(stream), [.pong(1), .error("boom")])
    }

    func testParserKeepsAPartialFrameBuffered() throws {
        var parser = ControlFrameParser()
        let frame = try ControlProtocol.frame(.pong, payload: Data([0, 0, 0, 0, 0, 0, 0, 2]))
        XCTAssertTrue(parser.append(frame.prefix(5)).isEmpty)
        XCTAssertEqual(parser.append(Data(frame.dropFirst(5))), [.pong(2)])
    }

    func testParserReportsMalformedFrameRatherThanThrowing() throws {
        var parser = ControlFrameParser()
        // DISPLAY_INFO with a two-byte payload cannot be decoded.
        let bad = try ControlProtocol.frame(.displayInfo, payload: Data([1, 2]))
        let messages = parser.append(bad)
        XCTAssertEqual(messages.count, 1)
        if case .error(let text) = messages[0] {
            XCTAssertTrue(text.contains("malformed"))
        } else {
            XCTFail("expected an error message, got \(messages[0])")
        }
    }

    // MARK: - Token

    func testTokenIs16HexCharacters() {
        let token = ControlServerLauncher.makeToken()
        XCTAssertEqual(token.count, 16)
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit })
        XCTAssertNotEqual(token, ControlServerLauncher.makeToken())
    }
}
