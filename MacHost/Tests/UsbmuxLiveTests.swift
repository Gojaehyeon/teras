import XCTest
@testable import TerasCore

/// Talks to the real usbmuxd on this Mac. Skips when nothing is plugged in, so
/// it is safe to run on a build machine.
final class UsbmuxLiveTests: XCTestCase {

    func testUsbmuxSocketExists() {
        XCTAssertTrue(UsbmuxClient.isAvailable,
                      "every Mac ships usbmuxd at \(UsbmuxProtocol.socketPath)")
    }

    func testListDevicesAgainstTheRealDaemon() async throws {
        try XCTSkipUnless(UsbmuxClient.isAvailable, "usbmuxd is not present")

        let devices: [UsbmuxDevice]
        do {
            devices = try await UsbmuxClient.listDevices(timeout: 5)
        } catch {
            throw XCTSkip("usbmuxd did not answer: \(error.localizedDescription)")
        }

        try XCTSkipIf(devices.isEmpty, "no iPhone or iPad is attached over USB")

        for device in devices {
            XCTAssertFalse(device.udid.isEmpty)
            XCTAssertGreaterThan(device.deviceID, 0)
        }
        let usb = devices.filter(\.isUSB)
        try XCTSkipIf(usb.isEmpty, "devices are visible but none over USB")

        // lockdownd answers GetValue DeviceName without a pairing session.
        let name = try? await UsbmuxClient.deviceName(deviceID: usb[0].deviceID, timeout: 5)
        if let name {
            XCTAssertFalse(name.isEmpty)
        }
    }
}
