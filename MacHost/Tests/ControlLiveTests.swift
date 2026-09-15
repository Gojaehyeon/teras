import XCTest
@testable import TerasCore

/// End-to-end smoke test for Teras Control against a real Android device.
///
/// It pushes the control server, starts it, forwards the socket and completes
/// the HELLO / READY / DISPLAY_INFO handshake — everything except the CGEvent
/// tap, which needs Accessibility permission and a human at the mouse.
///
/// Skipped unless `TERAS_CONTROL_E2E=1` is set and a jar can be found, so a
/// build machine with no phone attached still goes green.
final class ControlLiveTests: XCTestCase {

    /// The jar in the app bundle, or the one the Android build produced.
    private func jarURL() -> URL? {
        if let bundled = ControlServerLauncher.bundledJarURL() { return bundled }
        let built = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // MacHost
            .deletingLastPathComponent()      // teras
            .appendingPathComponent("Receivers/Android/control-server/build/teras-control.jar")
        return FileManager.default.fileExists(atPath: built.path) ? built : nil
    }

    func testHandshakeAgainstAnAttachedDevice() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TERAS_CONTROL_E2E"] == "1",
                          "set TERAS_CONTROL_E2E=1 to run against a real phone")
        let jar = try XCTUnwrap(jarURL(), "no teras-control.jar to push")

        let adb = AdbBridge()
        try XCTSkipUnless(adb.isInstalled, "adb is not installed")
        adb.startServer()

        let devices = (try? adb.devices()) ?? []
        let usable = devices.filter { $0.state == .device }
        try XCTSkipIf(usable.isEmpty, "no authorized Android device is attached")

        let serial = ProcessInfo.processInfo.environment["TERAS_CONTROL_SERIAL"] ?? usable[0].serial
        let launcher = ControlServerLauncher(serial: serial, adb: adb, jarURL: jar)
        defer { launcher.stop() }

        let info = try await launcher.start()
        XCTAssertGreaterThan(info.width, 0)
        XCTAssertGreaterThan(info.height, 0)
        XCTAssertTrue((0...3).contains(info.rotation))
        XCTAssertGreaterThan(info.density, 0)

        // A pointer move to the middle of the screen, then a hide: neither
        // should knock the link down.
        launcher.send([ControlProtocol.setPointerVisible(true),
                       ControlProtocol.pointerMove(x: Float(info.width) / 2, y: Float(info.height) / 2)])
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(launcher.isLive, "the link survived a pointer move")

        // Two heartbeat periods, to prove PING/PONG keeps it open.
        try await Task.sleep(nanoseconds: UInt64(2.5 * Double(NSEC_PER_SEC)))
        XCTAssertTrue(launcher.isLive, "the link survived past the 6 s ping timeout window")

        launcher.send([ControlProtocol.setPointerVisible(false)])
    }
}
