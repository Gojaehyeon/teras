import XCTest
@testable import TandemCore

final class UsbmuxProtocolTests: XCTestCase {

    func testNetworkPortIsByteSwapped() {
        // usbmuxd carries PortNumber in network byte order inside an integer.
        XCTAssertEqual(UsbmuxProtocol.networkPort(41777), 12707)
        XCTAssertEqual(UsbmuxProtocol.networkPort(62078), 32498)
        XCTAssertEqual(UsbmuxProtocol.networkPort(1), 256)
    }

    func testEncodedHeaderLayout() throws {
        let data = try UsbmuxProtocol.encode(UsbmuxProtocol.listDevicesRequest(), tag: 7)
        XCTAssertGreaterThan(data.count, UsbmuxProtocol.headerSize)

        XCTAssertEqual(Int(data.readLittleEndianUInt32(at: 0)), data.count, "length includes the header")
        XCTAssertEqual(data.readLittleEndianUInt32(at: 4), 1, "version")
        XCTAssertEqual(data.readLittleEndianUInt32(at: 8), 8, "plist type")
        XCTAssertEqual(data.readLittleEndianUInt32(at: 12), 7, "tag")

        let body = data.subdata(in: UsbmuxProtocol.headerSize..<data.count)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any])
        XCTAssertEqual(plist["MessageType"] as? String, "ListDevices")
        XCTAssertEqual(plist["ProgName"] as? String, "Tandem")
        XCTAssertNotNil(plist["ClientVersionString"])
    }

    func testConnectRequestCarriesDeviceAndPort() throws {
        let request = UsbmuxProtocol.connectRequest(deviceID: 42, port: 41777)
        XCTAssertEqual(request["MessageType"] as? String, "Connect")
        XCTAssertEqual(request["DeviceID"] as? Int, 42)
        XCTAssertEqual(request["PortNumber"] as? Int, 12707)
    }

    func testDecodeRoundTrip() throws {
        var buffer = try UsbmuxProtocol.encode(["MessageType": "Result", "Number": 0], tag: 3)
        let message = try XCTUnwrap(UsbmuxProtocol.decode(from: &buffer))
        XCTAssertEqual(message.tag, 3)
        XCTAssertEqual(message.messageType, "Result")
        XCTAssertTrue(buffer.isEmpty, "the decoded message is consumed")
        XCTAssertEqual(UsbmuxProtocol.event(from: message), .result(.ok))
    }

    func testDecodeWaitsForCompleteMessage() throws {
        let full = try UsbmuxProtocol.encode(["MessageType": "Result", "Number": 0], tag: 1)

        var partial = full.prefix(10)
        var buffer = Data(partial)
        XCTAssertNil(try UsbmuxProtocol.decode(from: &buffer), "header not yet complete")

        partial = full.prefix(UsbmuxProtocol.headerSize + 4)
        buffer = Data(partial)
        XCTAssertNil(try UsbmuxProtocol.decode(from: &buffer), "body not yet complete")

        buffer = full
        XCTAssertNotNil(try UsbmuxProtocol.decode(from: &buffer))
    }

    func testDecodeHandlesTwoMessagesInOneChunk() throws {
        var buffer = try UsbmuxProtocol.encode(["MessageType": "Result", "Number": 0], tag: 1)
        buffer.append(try UsbmuxProtocol.encode(["MessageType": "Result", "Number": 3], tag: 2))

        let first = try XCTUnwrap(UsbmuxProtocol.decode(from: &buffer))
        let second = try XCTUnwrap(UsbmuxProtocol.decode(from: &buffer))
        XCTAssertEqual(UsbmuxProtocol.event(from: first), .result(.ok))
        XCTAssertEqual(UsbmuxProtocol.event(from: second), .result(.connectionRefused))
        XCTAssertNil(try UsbmuxProtocol.decode(from: &buffer))
    }

    func testDecodeRejectsBadHeader() throws {
        var buffer = Data()
        buffer.appendLittleEndian(UInt32(20))
        buffer.appendLittleEndian(UInt32(9))   // wrong version
        buffer.appendLittleEndian(UInt32(8))
        buffer.appendLittleEndian(UInt32(1))
        buffer.append(Data(repeating: 0, count: 4))

        XCTAssertThrowsError(try UsbmuxProtocol.decode(from: &buffer)) { error in
            guard case UsbmuxError.badHeader(let version, let type)? = error as? UsbmuxError else {
                return XCTFail("expected badHeader, got \(error)")
            }
            XCTAssertEqual(version, 9)
            XCTAssertEqual(type, 8)
        }
    }

    func testDecodeRejectsOversizedLength() throws {
        var buffer = Data()
        buffer.appendLittleEndian(UInt32(UsbmuxProtocol.maxMessageSize + 1))
        buffer.appendLittleEndian(UInt32(1))
        buffer.appendLittleEndian(UInt32(8))
        buffer.appendLittleEndian(UInt32(1))
        XCTAssertThrowsError(try UsbmuxProtocol.decode(from: &buffer))
    }

    func testAttachedEventParsing() throws {
        let plist: [String: Any] = [
            "MessageType": "Attached",
            "DeviceID": 12,
            "Properties": [
                "ConnectionType": "USB",
                "SerialNumber": "00008150-00146D0A1180401C",
                "ProductID": 4776,
            ] as [String: Any],
        ]
        let event = UsbmuxProtocol.event(from: .init(tag: 0, plist: plist))
        guard case .attached(let device)? = event else { return XCTFail("expected attached, got \(String(describing: event))") }
        XCTAssertEqual(device.deviceID, 12)
        XCTAssertEqual(device.udid, "00008150-00146D0A1180401C")
        XCTAssertTrue(device.isUSB)
        XCTAssertEqual(device.productID, 4776)
    }

    func testAttachedOverNetworkIsNotUSB() throws {
        let plist: [String: Any] = [
            "MessageType": "Attached",
            "DeviceID": 3,
            "Properties": ["ConnectionType": "Network", "SerialNumber": "abc"] as [String: Any],
        ]
        guard case .attached(let device)? = UsbmuxProtocol.event(from: .init(tag: 0, plist: plist)) else {
            return XCTFail("expected attached")
        }
        XCTAssertFalse(device.isUSB)
    }

    func testDetachedEventParsing() {
        let event = UsbmuxProtocol.event(from: .init(tag: 0, plist: ["MessageType": "Detached", "DeviceID": 9]))
        XCTAssertEqual(event, .detached(9))
    }

    func testDeviceListParsing() {
        let plist: [String: Any] = [
            "DeviceList": [
                ["DeviceID": 1, "Properties": ["ConnectionType": "USB", "SerialNumber": "aaa"] as [String: Any]],
                ["DeviceID": 2, "Properties": ["ConnectionType": "USB", "SerialNumber": "bbb"] as [String: Any]],
                ["DeviceID": 3, "Properties": ["ConnectionType": "USB"] as [String: Any]],  // no udid: dropped
            ] as [[String: Any]],
        ]
        let devices = UsbmuxProtocol.devices(fromListReply: plist)
        XCTAssertEqual(devices.map(\.udid), ["aaa", "bbb"])
    }

    // MARK: - lockdownd framing

    func testLockdownRequestUsesBigEndianLength() throws {
        let data = try UsbmuxProtocol.deviceNameRequest()
        XCTAssertGreaterThan(data.count, 4)

        var length: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &length) { destination in
            data.copyBytes(to: destination.bindMemory(to: UInt8.self), from: 0..<4)
        }
        XCTAssertEqual(Int(UInt32(bigEndian: length)), data.count - 4)

        let body = data.subdata(in: 4..<data.count)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any])
        XCTAssertEqual(plist["Request"] as? String, "GetValue")
        XCTAssertEqual(plist["Key"] as? String, "DeviceName")
        XCTAssertEqual(plist["Label"] as? String, "Tandem")
    }

    func testLockdownReplyDecoding() throws {
        var buffer = try UsbmuxProtocol.lockdownRequest(["Request": "GetValue", "Value": "Go's iPhone"])
        let reply = try XCTUnwrap(UsbmuxProtocol.decodeLockdownReply(from: &buffer))
        XCTAssertEqual(UsbmuxProtocol.deviceName(fromLockdownReply: reply), "Go's iPhone")
        XCTAssertTrue(buffer.isEmpty)
    }

    func testLockdownReplyWaitsForBody() throws {
        let full = try UsbmuxProtocol.lockdownRequest(["Value": "x"])
        var buffer = Data(full.prefix(6))
        XCTAssertNil(try UsbmuxProtocol.decodeLockdownReply(from: &buffer))
    }
}
