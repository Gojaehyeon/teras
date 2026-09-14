import XCTest
@testable import TerasCore

final class AdbParsingTests: XCTestCase {

    // MARK: - forward

    func testForwardedPortFromBareNumber() {
        XCTAssertEqual(AdbParsing.forwardedPort(from: "54321\n"), 54321)
    }

    func testForwardedPortIgnoresDaemonChatter() {
        let output = """
        * daemon not running; starting now at tcp:5137
        * daemon started successfully
        41999
        """
        XCTAssertEqual(AdbParsing.forwardedPort(from: output), 41999)
    }

    func testForwardedPortRejectsNonPortOutput() {
        XCTAssertNil(AdbParsing.forwardedPort(from: "error: device offline\n"))
        XCTAssertNil(AdbParsing.forwardedPort(from: ""))
        XCTAssertNil(AdbParsing.forwardedPort(from: "70000\n"), "out of range")
    }

    // MARK: - track-devices

    func testParseDeviceListStates() {
        let block = """
        R5CT30ABCDE\tdevice
        emulator-5554\toffline
        9A2B1C3D\tunauthorized
        """
        let devices = AdbParsing.parseDeviceList(block)
        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(devices[0], AdbDevice(serial: "R5CT30ABCDE", state: .device, model: nil))
        XCTAssertEqual(devices[1].state, .offline)
        XCTAssertEqual(devices[2].state, .unauthorized)
        XCTAssertTrue(devices[0].state.isUsable)
        XCTAssertFalse(devices[2].state.isUsable)
    }

    func testParseDeviceListSkipsHeadersAndDaemonLines() {
        let block = """
        * daemon not running; starting now at tcp:5137
        * daemon started successfully
        List of devices attached
        R5CT30ABCDE\tdevice
        """
        XCTAssertEqual(AdbParsing.parseDeviceList(block).map(\.serial), ["R5CT30ABCDE"])
    }

    func testParseDeviceListReadsModelFromLongForm() {
        let block = "R5CT30ABCDE           device product:a54x model:SM_A546E device:a54x transport_id:1"
        let devices = AdbParsing.parseDeviceList(block)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].state, .device)
        XCTAssertEqual(devices[0].model, "SM A546E")
        XCTAssertEqual(devices[0].displayName, "SM A546E")
    }

    func testParseDeviceListHandlesMultiWordState() {
        let devices = AdbParsing.parseDeviceList("1234abcd\tno permissions")
        XCTAssertEqual(devices.first?.state, .noPermissions)
    }

    func testEmptySnapshotIsEmpty() {
        XCTAssertTrue(AdbParsing.parseDeviceList("").isEmpty)
        XCTAssertTrue(AdbParsing.parseDeviceList("\n\n").isEmpty)
    }

    func testTakeSnapshotsSplitsOnBlankLines() {
        var buffer = "A1\tdevice\n\nA1\tdevice\nB2\tunauthorized\n\nA1\tdev"
        let snapshots = AdbParsing.takeSnapshots(from: &buffer)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].map(\.serial), ["A1"])
        XCTAssertEqual(snapshots[1].map(\.serial), ["A1", "B2"])
        XCTAssertEqual(buffer, "A1\tdev", "the partial snapshot is kept for the next read")
    }

    func testTakeSnapshotsReturnsNothingForPartialInput() {
        var buffer = "A1\tdevice\n"
        XCTAssertTrue(AdbParsing.takeSnapshots(from: &buffer).isEmpty)
        XCTAssertEqual(buffer, "A1\tdevice\n")
    }

    // MARK: - length prefix

    func testStripLengthPrefixRemovesHostServicePrefix() {
        XCTAssertEqual(AdbParsing.stripLengthPrefix("0014R5CT30ABCDE\tdevice"), "R5CT30ABCDE\tdevice")
    }

    func testStripLengthPrefixLeavesHexSerialsAlone() {
        // A serial that happens to start with four hex digits, no tab: untouched.
        XCTAssertEqual(AdbParsing.stripLengthPrefix("1234abcd"), "1234abcd")
    }

    func testModelParsing() {
        XCTAssertEqual(AdbParsing.model(from: "Pixel 8 Pro\n"), "Pixel 8 Pro")
        XCTAssertNil(AdbParsing.model(from: "  \n"))
    }
}
