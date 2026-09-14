import XCTest
import TerasProtocol
@testable import TerasCore

/// The host side of PROTOCOL §8, driven end to end against a fake receiver.
@MainActor
final class HandshakeTests: XCTestCase {

    private var channel: FakePeerChannel!
    private var display: FakeDisplayHost!
    private var pipeline: FakePipeline!
    private var input: FakeInputSink!
    private var secrets: MemorySecretStore!
    private var settings: DeviceSettingsStore!
    /// The session under test. Held here because a `DisplaySession` keeps only
    /// weak references from its own callbacks; a local would deallocate it.
    private var session: DisplaySession!

    override func setUp() {
        super.setUp()
        channel = FakePeerChannel()
        display = FakeDisplayHost()
        pipeline = FakePipeline()
        input = FakeInputSink()
        secrets = MemorySecretStore()
        settings = Fixtures.settingsStore()
    }

    override func tearDown() {
        session = nil
        super.tearDown()
    }

    private func makeSession(transport: Transport = .usb,
                             endpoint: TerasEndpoint? = nil) -> DisplaySession {
        let dependencies = SessionDependencies(
            hostId: Fixtures.hostId,
            hostName: "Test Mac",
            appInfo: AppInfo(name: "Teras", version: "1.0.0", build: 1),
            pairingStore: secrets,
            settingsStore: settings,
            makeDisplay: { [display] _ in display! },
            makePipeline: { [pipeline] in pipeline! },
            makeInput: { [input] _ in input! })

        let defaultEndpoint: TerasEndpoint = transport == .usb
            ? .usbIOS(udid: "UDID-TEST", deviceID: 3, name: "Test iPhone")
            : .lan(peer: LanPeer(endpoint: .hostPort(host: "192.0.2.7", port: 41777),
                                 deviceId: Fixtures.deviceId,
                                 name: "Test iPhone",
                                 platform: .ios,
                                 protocolVersion: 1))

        session = DisplaySession(endpoint: endpoint ?? defaultEndpoint,
                                 channel: channel,
                                 transport: transport,
                                 dependencies: dependencies,
                                 hostNonce: Fixtures.hostNonce)
        return session
    }

    // MARK: - USB: no authentication

    func testHelloIsSentOnStart() throws {
        let session = makeSession()
        session.start()

        let hello: Hello = try channel.decodeFirst(.hello)
        XCTAssertEqual(hello.pv, Teras.protocolVersion)
        XCTAssertEqual(hello.hostId, Fixtures.hostId)
        XCTAssertEqual(hello.hostName, "Test Mac")
        XCTAssertEqual(hello.transport, .usb)
        XCTAssertEqual(hello.hostNonce, Fixtures.hostNonce)
        XCTAssertFalse(hello.encrypt, "USB does not ask for the encrypted envelope")
        XCTAssertEqual(session.state, .handshaking)
    }

    func testHelloAckWithoutAuthGoesStraightToStreamConfig() throws {
        let session = makeSession()
        session.start()
        try channel.deliver(.helloAck, Fixtures.helloAck(authRequired: false))

        XCTAssertEqual(session.state, .configuring)
        let config: StreamConfig = try channel.decodeFirst(.streamConfig)
        XCTAssertEqual(config.codec, .hevc, "HEVC is preferred when the receiver offers it")
        XCTAssertEqual(config.wPx, 2556)
        XCTAssertEqual(config.hPx, 1176)
        XCTAssertEqual(config.desktop, Size(w: 1278, h: 588))
        XCTAssertEqual(config.fps, 60)
        XCTAssertEqual(config.orientation, .landscapeLeft)
        XCTAssertEqual(config.mode, .extend)
        XCTAssertTrue(config.cursorBaked)

        XCTAssertEqual(display.createdSpecs.count, 1)
        XCTAssertEqual(display.createdSpecs.first?.hiDPI, true)
        XCTAssertEqual(display.createdNames.first, "Test iPhone")
    }

    func testReadyStartsTheVideoPipeline() async throws {
        let session = makeSession()
        session.start()
        try channel.deliver(.helloAck, Fixtures.helloAck(authRequired: false))
        XCTAssertEqual(pipeline.startCount, 0, "nothing streams before READY")

        try channel.deliver(.ready, [String: String]())
        await waitUntil("the session to start streaming") { session.state == .streaming }

        XCTAssertEqual(pipeline.startCount, 1)
        XCTAssertEqual(pipeline.lastCodec, .hevc)
        XCTAssertEqual(pipeline.lastSpec?.encodedWidth, 2556)
        // High preset over USB.
        XCTAssertEqual(pipeline.lastBitrate, QualityPreset.high.bitsPerSecond(transport: .usb))
    }

    func testH264IsUsedWhenTheReceiverCannotDecodeHEVC() throws {
        let session = makeSession()
        session.start()
        try channel.deliver(.helloAck, Fixtures.helloAck(authRequired: false, codecs: [.h264]))

        let config: StreamConfig = try channel.decodeFirst(.streamConfig)
        XCTAssertEqual(config.codec, .h264)
        XCTAssertLessThanOrEqual(config.wPx, CodecLimits.avcMaxWidth)
        XCTAssertEqual(session.state, .configuring)
    }

    func testSessionFailsWhenNoCodecIsShared() throws {
        let session = makeSession()
        session.start()
        try channel.deliver(.helloAck, Fixtures.helloAck(authRequired: false, codecs: []))

        guard case .failed(let reason) = session.state else {
            return XCTFail("expected a failed session, got \(session.state)")
        }
        XCTAssertTrue(reason.contains("codec"), reason)
        XCTAssertTrue(channel.cancelled)
    }

    // MARK: - LAN: pairing then authentication

    func testPairingFlowProducesTheVectorProofs() throws {
        let session = makeSession(transport: .lan)
        session.start()

        let hello: Hello = try channel.decodeFirst(.hello)
        XCTAssertTrue(hello.encrypt, "LAN asks for the encrypted envelope")

        try channel.deliver(.helloAck, Fixtures.helloAck(authRequired: true, paired: false))
        try channel.deliver(.pairRequired, PairRequired(attemptsLeft: 3))
        XCTAssertEqual(session.state, .awaitingPIN(attemptsLeft: 3))
        XCTAssertNil(channel.firstFrame(.pair), "nothing is sent until the user types the code")

        session.providePIN(Fixtures.pin)
        XCTAssertEqual(session.state, .pairing)

        let pair: PairMessage = try channel.decodeFirst(.pair)
        XCTAssertEqual(pair.proof.hexString,
                       "110062869395c85646afbcf6e8de85c902b69c610c2d469d7fa471763d59d690",
                       "matches docs/VECTORS.md pairProof")

        // The receiver seals the new secret with the same PIN key.
        let pinKey = TerasCrypto.pinKey(pin: Fixtures.pin, deviceId: Fixtures.deviceId, hostId: Fixtures.hostId)
        let box = try TerasCrypto.sealPairBox(secret: Fixtures.secret,
                                               pinKey: pinKey,
                                               hostNonce: Fixtures.hostNonce,
                                               deviceNonce: Fixtures.deviceNonce)
        try channel.deliver(.pairOK, PairOK(box: box))

        XCTAssertEqual(secrets.secret(forDeviceId: Fixtures.deviceId), Fixtures.secret,
                       "the recovered secret is stored under the device id")
        XCTAssertEqual(session.state, .authenticating)

        let auth: AuthMessage = try channel.decodeFirst(.auth)
        XCTAssertEqual(auth.proof.hexString,
                       "d68dfc86e14f407a12db80aa5d552db1c3085d01aa2964a0cfa6dcb6c788f76f",
                       "matches docs/VECTORS.md authProof")
    }

    func testAuthOKEnablesEncryptionAndConfiguresTheStream() throws {
        let session = makeSession(transport: .lan)
        secrets.save(secret: Fixtures.secret, forDeviceId: Fixtures.deviceId)
        session.start()

        try channel.deliver(.helloAck, Fixtures.helloAck(authRequired: true, paired: true))
        XCTAssertEqual(session.state, .authenticating, "a known device skips pairing")

        let ackProof = TerasCrypto.authAckProof(secret: Fixtures.secret,
                                                 hostNonce: Fixtures.hostNonce,
                                                 deviceNonce: Fixtures.deviceNonce)
        XCTAssertEqual(ackProof.hexString,
                       "a72b55ef64bc87c44e8a798addb5ba7600e9491d8275c47166fd47fddaf28bce",
                       "matches docs/VECTORS.md authAckProof")
        try channel.deliver(.authOK, AuthOK(proof: ackProof))

        let keys = try XCTUnwrap(channel.encryptionKeys)
        XCTAssertEqual(keys.h2r.hexString, "2be1636a55b023d61f070f8d225e48be67fccf9721773695b73c5410b4d9cd26")
        XCTAssertEqual(keys.r2h.hexString, "65aaf0ab94238a685aa8aa78efddaf2272ba0257782653cfacd1366749283e90")
        XCTAssertEqual(session.state, .configuring)
        XCTAssertNotNil(channel.firstFrame(.streamConfig))
    }

    func testAuthOKWithABadProofFailsTheSessionAndKeepsTheSecret() throws {
        let session = makeSession(transport: .lan)
        secrets.save(secret: Fixtures.secret, forDeviceId: Fixtures.deviceId)
        session.start()
        try channel.deliver(.helloAck, Fixtures.helloAck(authRequired: true, paired: true))
        try channel.deliver(.authOK, AuthOK(proof: Data(repeating: 0xAB, count: 32)))

        guard case .failed = session.state else {
            return XCTFail("expected a failed session, got \(session.state)")
        }
        XCTAssertNil(channel.encryptionKeys, "nothing is encrypted with an unproven peer")
        XCTAssertEqual(secrets.secret(forDeviceId: Fixtures.deviceId), Fixtures.secret,
                       "a wrong answer from the far end is not a reason to drop our own key")
    }

    func testAuthFailDropsTheStoredSecret() throws {
        let session = makeSession(transport: .lan)
        secrets.save(secret: Fixtures.secret, forDeviceId: Fixtures.deviceId)
        session.start()
        try channel.deliver(.helloAck, Fixtures.helloAck(authRequired: true, paired: true))
        try channel.deliver(.authFail, AuthFail(reason: "unknown host"))

        guard case .failed = session.state else {
            return XCTFail("expected a failed session, got \(session.state)")
        }
        XCTAssertNil(secrets.secret(forDeviceId: Fixtures.deviceId),
                     "the stale key is dropped so the next attempt can pair")
    }

    func testPairFailKeepsAskingUntilTheDeviceLocks() throws {
        let session = makeSession(transport: .lan)
        session.start()
        try channel.deliver(.helloAck, Fixtures.helloAck(authRequired: true, paired: false))
        try channel.deliver(.pairRequired, PairRequired(attemptsLeft: 3))

        session.providePIN("000000")
        try channel.deliver(.pairFail, PairFail(attemptsLeft: 2, locked: false))
        XCTAssertEqual(session.state, .awaitingPIN(attemptsLeft: 2))

        session.providePIN("000001")
        try channel.deliver(.pairFail, PairFail(attemptsLeft: 0, locked: true))
        guard case .failed = session.state else {
            return XCTFail("expected a failed session, got \(session.state)")
        }
    }

    func testPairedDeviceWithNoLocalSecretFailsWithAdvice() throws {
        let session = makeSession(transport: .lan)
        session.start()
        try channel.deliver(.helloAck, Fixtures.helloAck(authRequired: true, paired: true))

        guard case .failed(let reason) = session.state else {
            return XCTFail("expected a failed session, got \(session.state)")
        }
        XCTAssertTrue(reason.lowercased().contains("pair again"), reason)
    }

    func testDisplayCreationFailureEndsTheSessionWithAReadableReason() throws {
        // CGVirtualDisplay(descriptor:) returns nil on some macOS builds; that
        // has to reach the user as a message, not a crash.
        display.createError = VirtualDisplayError.creationFailed
        let session = makeSession()
        session.start()
        try channel.deliver(.helloAck, Fixtures.helloAck(authRequired: false))

        guard case .failed(let reason) = session.state else {
            return XCTFail("expected a failed session, got \(session.state)")
        }
        XCTAssertTrue(reason.contains("virtual display"), reason)
        XCTAssertNil(channel.firstFrame(.streamConfig), "nothing is promised that we cannot deliver")
        XCTAssertTrue(channel.cancelled)
    }

    func testPongTimeoutReleasesTheDisplayImmediately() async throws {
        let session = try await streamingSession()
        channel.fail(PeerConnectionError.pongTimeout)

        // A locked phone must not leave a virtual display stranded on the Mac.
        XCTAssertEqual(display.destroyCount, 1)
        XCTAssertEqual(pipeline.stopCount, 1)
        guard case .closed(let reason) = session.state else {
            return XCTFail("expected a closed session, got \(session.state)")
        }
        XCTAssertTrue(reason.contains("PONG"), reason)
    }

    // MARK: - Running session

    func testKeyframeRequestReachesThePipeline() async throws {
        let session = try await streamingSession()
        channel.deliver(Frame(type: .keyframeRequest))

        XCTAssertEqual(pipeline.keyframeRequests, 1)
        XCTAssertEqual(pipeline.replayCount, 1, "a static desktop still needs a picture to send")
        XCTAssertTrue(session.state.isStreaming)
    }

    func testInputIsForwardedToTheInjector() async throws {
        _ = try await streamingSession()

        let touch = TouchEvent(phase: .began, pointers: [TouchPointer(id: 1, tool: .finger, x: 0.5, y: 0.25)])
        channel.deliver(touch.frame())
        channel.deliver(ScrollEvent(x: 0.5, y: 0.5, dx: 0, dy: -40, phase: .changed).frame())
        channel.deliver(PointerEvent(kind: .down, button: .right, x: 0.1, y: 0.2).frame())
        try channel.deliver(.key, KeyEvent(down: true, keyCode: 0, text: "a", mods: ["cmd"]))

        XCTAssertEqual(input.touches, [touch])
        XCTAssertEqual(input.scrolls.count, 1)
        XCTAssertEqual(input.pointers.first?.button, .right)
        XCTAssertEqual(input.keys.first?.text, "a")
    }

    func testStatsAreStoredAndPublished() async throws {
        let session = try await streamingSession()
        var published: Stats?
        session.onStatsChange = { published = $0 }

        let stats = Stats(fpsDecoded: 59.8, fpsDropped: 0, decodeMsP50: 3.1, queued: 1, rttMs: 2.4, e2eMsP50: 18.5)
        try channel.deliver(.stats, stats)

        XCTAssertEqual(session.stats, stats)
        XCTAssertEqual(published, stats)
    }

    func testDeviceConfigRebuildsTheDisplayAndReoffersTheStream() async throws {
        let session = try await streamingSession()
        XCTAssertEqual(display.createdSpecs.count, 1)

        let rotated = DeviceConfig(orientation: .portrait,
                                   screen: ScreenInfo(wPx: 1179, hPx: 2556, scale: 3, refreshHz: 120))
        try channel.deliver(.deviceConfig, rotated)

        XCTAssertEqual(display.createdSpecs.count, 2, "the display is rebuilt for the new orientation")
        let latest = try XCTUnwrap(display.createdSpecs.last)
        XCTAssertGreaterThan(latest.encodedHeight, latest.encodedWidth, "now portrait")
        XCTAssertEqual(pipeline.stopCount, 1, "the old encode session is torn down first")
        XCTAssertEqual(session.state, .configuring)

        let configs = channel.sent.filter { $0.type == .streamConfig }
        XCTAssertEqual(configs.count, 2)
        let second = try configs[1].decode(StreamConfig.self)
        XCTAssertEqual(second.orientation, .portrait)
    }

    func testIdenticalDeviceConfigIsIgnored() async throws {
        _ = try await streamingSession()
        let same = DeviceConfig(orientation: .landscapeLeft,
                                screen: ScreenInfo(wPx: 2556, hPx: 1179, scale: 3, refreshHz: 120))
        try channel.deliver(.deviceConfig, same)

        XCTAssertEqual(display.createdSpecs.count, 1, "no pointless display rebuild")
        XCTAssertEqual(channel.sent.filter { $0.type == .streamConfig }.count, 1)
    }

    func testByeTearsTheSessionDown() async throws {
        let session = try await streamingSession()
        try channel.deliver(.bye, Bye(reason: "user closed the app"))

        XCTAssertEqual(session.state, .closed("user closed the app"))
        XCTAssertEqual(display.destroyCount, 1, "the virtual display is given back")
        XCTAssertEqual(pipeline.stopCount, 1)
        XCTAssertTrue(channel.cancelled)
    }

    func testStopSendsByeAndTearsDown() async throws {
        let session = try await streamingSession()
        session.stop(reason: "the user disconnected this device")

        let bye: Bye = try channel.decodeFirst(.bye)
        XCTAssertEqual(bye.reason, "the user disconnected this device")
        XCTAssertEqual(display.destroyCount, 1)
        XCTAssertTrue(channel.cancelled)
    }

    func testTransportFailureClosesTheSessionAndReleasesTheDisplay() async throws {
        let session = try await streamingSession()
        channel.fail(PeerConnectionError.pongTimeout)

        guard case .closed = session.state else {
            return XCTFail("expected a closed session, got \(session.state)")
        }
        XCTAssertEqual(display.destroyCount, 1)
    }

    func testUnknownFrameTypesAreIgnored() async throws {
        let session = try await streamingSession()
        // READY is a legal type but not expected twice; it must not upset us.
        channel.deliver(Frame(type: .ready))
        XCTAssertTrue(session.state.isStreaming)
    }

    // MARK: - Video

    func testEncodedFramesBecomeVideoFramesWithIncreasingSequence() async throws {
        _ = try await streamingSession()

        pipeline.emit(EncodedFrame(annexB: Data([0, 0, 0, 1, 0x26]), isKeyframe: true,
                                   hasParameterSets: true, captureTimestampUs: 1_000))
        pipeline.emit(EncodedFrame(annexB: Data([0, 0, 0, 1, 0x02]), isKeyframe: false,
                                   hasParameterSets: false, captureTimestampUs: 17_000))

        XCTAssertEqual(channel.videoSent.count, 2)
        let first = try VideoFrame(parsing: channel.videoSent[0].payload)
        let second = try VideoFrame(parsing: channel.videoSent[1].payload)

        XCTAssertEqual(first.seq, 1)
        XCTAssertEqual(second.seq, 2)
        XCTAssertTrue(first.flags.contains(.keyframe))
        XCTAssertTrue(first.flags.contains(.hasParameterSets))
        XCTAssertFalse(second.flags.contains(.keyframe))
        XCTAssertEqual(first.captureTimestampUs, 1_000)
        XCTAssertEqual(second.captureTimestampUs, 17_000)
    }

    func testFramesAreDroppedWhenTheSendQueueBacksUp() async throws {
        _ = try await streamingSession()
        channel.videoBacklog = VideoSender.maxBacklog + 1

        pipeline.emit(EncodedFrame(annexB: Data([1]), isKeyframe: false,
                                   hasParameterSets: false, captureTimestampUs: 1))
        XCTAssertTrue(channel.videoSent.isEmpty, "a stale picture is worth less than the latency it costs")

        // Dropping must be followed by a fresh IDR so the decoder recovers.
        await waitUntil("a keyframe to be requested after a drop") { [pipeline] in
            pipeline!.keyframeRequests >= 1
        }

        channel.videoBacklog = 0
        pipeline.emit(EncodedFrame(annexB: Data([2]), isKeyframe: true,
                                   hasParameterSets: true, captureTimestampUs: 2))
        let frame = try VideoFrame(parsing: try XCTUnwrap(channel.videoSent.first).payload)
        XCTAssertTrue(frame.flags.contains(.discontinuity), "the receiver is told it missed pictures")
    }

    func testKeyframesAreSentEvenWhenTheQueueIsBackedUp() async throws {
        _ = try await streamingSession()
        channel.videoBacklog = VideoSender.maxBacklog + 5

        pipeline.emit(EncodedFrame(annexB: Data([9]), isKeyframe: true,
                                   hasParameterSets: true, captureTimestampUs: 3))
        XCTAssertEqual(channel.videoSent.count, 1, "dropping the IDR would leave the receiver blank")
    }

    // MARK: - Settings

    func testQualityChangeRetargetsTheEncoderWithoutRebuildingTheDisplay() async throws {
        let session = try await streamingSession()
        session.applyQuality(.low)

        XCTAssertEqual(pipeline.lastBitrate, QualityPreset.low.bitsPerSecond(transport: .usb))
        XCTAssertEqual(display.createdSpecs.count, 1, "quality alone does not change geometry")
        XCTAssertEqual(settings.settings(for: "usb-ios:UDID-TEST").quality, .low)
    }

    func testLanQualityIsCappedBelowTheUsbPreset() {
        XCTAssertEqual(QualityPreset.ultra.megabitsPerSecond(transport: .usb), 60)
        XCTAssertEqual(QualityPreset.ultra.megabitsPerSecond(transport: .lan), QualityPreset.lanCapMbps)
        XCTAssertEqual(QualityPreset.low.megabitsPerSecond(transport: .lan), 8, "already under the cap")
    }

    // MARK: - Helper

    /// Drive a USB session all the way to streaming.
    private func streamingSession() async throws -> DisplaySession {
        let session = makeSession()
        session.start()
        try channel.deliver(.helloAck, Fixtures.helloAck(authRequired: false))
        try channel.deliver(.ready, [String: String]())
        await waitUntil("the session to start streaming") { session.state == .streaming }
        return session
    }
}
