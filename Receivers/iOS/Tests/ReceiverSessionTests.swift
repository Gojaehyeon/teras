import XCTest
import TerasProtocol
@testable import TerasReceiver

final class ReceiverSessionTests: XCTestCase {

    // MARK: - USB path

    func testUSBPathReachesReadyWithoutAuthentication() throws {
        let channel = FakeChannel(linkTransport: .usb)
        let (session, delegate, sink) = Fixtures.makeSession(channel: channel)

        session.handle(Fixtures.hello(transport: .usb))

        let ackFrame = try XCTUnwrap(channel.firstFrame(ofType: .helloAck))
        let ack: HelloAck = try ackFrame.decode()
        XCTAssertEqual(ack.pv, Teras.protocolVersion)
        XCTAssertEqual(ack.deviceId, Vectors.deviceId)
        XCTAssertEqual(ack.platform, .ios)
        XCTAssertEqual(ack.model, "iPhone16,1")
        XCTAssertEqual(ack.deviceNonce, Vectors.deviceNonce)
        XCTAssertEqual(ack.screen.wPx, 1179)
        XCTAssertEqual(ack.screen.hPx, 2556)
        XCTAssertEqual(ack.codecs, [.hevc, .h264])
        XCTAssertEqual(ack.maxDecode, Size(w: 4096, h: 2304))
        XCTAssertFalse(ack.authRequired)
        XCTAssertFalse(ack.paired)
        XCTAssertEqual(session.state, .configuring)
        XCTAssertFalse(channel.types.contains(.pairRequired))

        session.handle(Fixtures.streamConfig())

        XCTAssertEqual(channel.types, [.helloAck, .ready])
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(sink.configurations.count, 1)
        XCTAssertEqual(sink.configurations.first?.codec, .hevc)
        XCTAssertEqual(delegate.configs.count, 1)
        XCTAssertEqual(delegate.states, [.configuring, .streaming])
    }

    func testVideoFramesReachTheSinkOnlyWhileStreaming() throws {
        let channel = FakeChannel(linkTransport: .usb)
        let (session, _, sink) = Fixtures.makeSession(channel: channel)

        let video = VideoFrame(flags: [.keyframe, .hasParameterSets],
                               captureTimestampUs: 1_234,
                               seq: 7,
                               annexB: Data([0x00, 0x00, 0x00, 0x01, 0x65, 0xAA]))

        session.handle(video.frame())
        XCTAssertTrue(sink.frames.isEmpty, "video before STREAM_CONFIG must be ignored")

        session.handle(Fixtures.hello(transport: .usb))
        session.handle(Fixtures.streamConfig())
        session.handle(video.frame())

        XCTAssertEqual(sink.frames.count, 1)
        XCTAssertEqual(sink.frames.first?.seq, 7)
        XCTAssertEqual(sink.frames.first?.captureTimestampUs, 1_234)
        XCTAssertTrue(sink.frames.first?.flags.contains(.keyframe) ?? false)
    }

    func testStatsAreSentFromTheSinkSnapshot() throws {
        let channel = FakeChannel(linkTransport: .usb)
        channel.roundTripMs = 2.5
        let (session, _, sink) = Fixtures.makeSession(channel: channel)
        sink.stats = VideoStatsSnapshot(fpsDecoded: 59, fpsDropped: 1, decodeMsP50: 3.5,
                                        queued: 1, e2eMsP50: 18.25, codec: "hevc", width: 2556, height: 1179)

        session.handle(Fixtures.hello(transport: .usb))
        session.handle(Fixtures.streamConfig())
        session.sendStats()

        let statsFrame = try XCTUnwrap(channel.firstFrame(ofType: .stats))
        let stats: Stats = try statsFrame.decode()
        XCTAssertEqual(stats.fpsDecoded, 59)
        XCTAssertEqual(stats.fpsDropped, 1)
        XCTAssertEqual(stats.decodeMsP50, 3.5)
        XCTAssertEqual(stats.queued, 1)
        XCTAssertEqual(stats.rttMs, 2.5)
        XCTAssertEqual(stats.e2eMsP50, 18.25)
    }

    func testDeviceConfigIsSentOncePerDistinctGeometry() throws {
        let channel = FakeChannel(linkTransport: .usb)
        let (session, _, _) = Fixtures.makeSession(channel: channel)
        session.handle(Fixtures.hello(transport: .usb))
        session.handle(Fixtures.streamConfig())

        let screen = ScreenInfo(wPx: 2556, hPx: 1179, scale: 3, refreshHz: 120, safeInsets: SafeInsets())
        session.sendDeviceConfig(orientation: .landscapeLeft, screen: screen)
        session.sendDeviceConfig(orientation: .landscapeLeft, screen: screen)

        XCTAssertEqual(channel.frames(ofType: .deviceConfig).count, 1)
        let config: DeviceConfig = try XCTUnwrap(channel.firstFrame(ofType: .deviceConfig)).decode()
        XCTAssertEqual(config.orientation, .landscapeLeft)
        XCTAssertEqual(config.screen.wPx, 2556)

        session.sendDeviceConfig(orientation: .portrait, screen: screen)
        XCTAssertEqual(channel.frames(ofType: .deviceConfig).count, 2)
    }

    func testInputIsDroppedUntilStreaming() {
        let channel = FakeChannel(linkTransport: .usb)
        let (session, _, _) = Fixtures.makeSession(channel: channel)
        let touch = TouchEvent(phase: .began,
                               pointers: [TouchPointer(id: 1, tool: .finger, x: 0.5, y: 0.5)]).frame()

        session.sendInput(touch)
        XCTAssertTrue(channel.frames(ofType: .touch).isEmpty)

        session.handle(Fixtures.hello(transport: .usb))
        session.handle(Fixtures.streamConfig())
        session.sendInput(touch)
        XCTAssertEqual(channel.frames(ofType: .touch).count, 1)
    }

    func testByeEndsTheSession() {
        let channel = FakeChannel(linkTransport: .usb)
        let (session, delegate, sink) = Fixtures.makeSession(channel: channel)
        session.handle(Fixtures.hello(transport: .usb))
        session.handle(Fixtures.streamConfig())

        session.handle(try! Frame.json(.bye, Bye(reason: "host quit")))

        XCTAssertEqual(session.state, .closed("host quit"))
        XCTAssertEqual(delegate.endReasons, ["host quit"])
        XCTAssertTrue(channel.isClosed)
        XCTAssertEqual(channel.closeReasons, [nil], "BYE from the host is not echoed back")
        XCTAssertEqual(sink.resetCount, 1)
    }

    // MARK: - LAN pairing against docs/VECTORS.md

    func testLANPairingProducesTheDocumentedProofsAndBox() throws {
        let channel = FakeChannel(linkTransport: .lan)
        let store = MemoryPairingStore()
        let (session, _, _) = Fixtures.makeSession(channel: channel, store: store)

        session.handle(Fixtures.hello(transport: .lan, encrypt: true))

        let ack: HelloAck = try XCTUnwrap(channel.firstFrame(ofType: .helloAck)).decode()
        XCTAssertTrue(ack.authRequired)
        XCTAssertFalse(ack.paired)

        let required: PairRequired = try XCTUnwrap(channel.firstFrame(ofType: .pairRequired)).decode()
        XCTAssertEqual(required.attemptsLeft, Teras.pairMaxAttempts)
        XCTAssertEqual(session.state, .pairing(pin: Vectors.pin, attemptsLeft: 3))

        // The proof the Mac derives from PIN 123456 and the two nonces.
        XCTAssertEqual(TerasCrypto.pinKey(pin: Vectors.pin,
                                           deviceId: Vectors.deviceId,
                                           hostId: Vectors.hostId), Vectors.pinKey)
        session.handle(try Frame.json(.pair, PairMessage(proof: Vectors.pairProof)))

        let pairOK: PairOK = try XCTUnwrap(channel.firstFrame(ofType: .pairOK)).decode()
        XCTAssertEqual(pairOK.box.hexString, Vectors.pairBox.hexString)
        XCTAssertEqual(store.secret(forHost: Vectors.hostId), Vectors.secret)
        XCTAssertEqual(session.state, .authenticating)

        session.handle(try Frame.json(.auth, AuthMessage(proof: Vectors.authProof)))

        let authOK: AuthOK = try XCTUnwrap(channel.firstFrame(ofType: .authOK)).decode()
        XCTAssertEqual(authOK.proof.hexString, Vectors.authAckProof.hexString)
        XCTAssertEqual(session.state, .configuring)

        // hello.encrypt was true, so both directions switch to the envelope.
        let keys = try XCTUnwrap(channel.encryptionKeys)
        XCTAssertEqual(keys.h2r.hexString, Vectors.keyH2R.hexString)
        XCTAssertEqual(keys.r2h.hexString, Vectors.keyR2H.hexString)

        session.handle(Fixtures.streamConfig())
        XCTAssertEqual(channel.types, [.helloAck, .pairRequired, .pairOK, .authOK, .ready])
        XCTAssertEqual(session.state, .streaming)
    }

    func testAlreadyPairedHostSkipsPairing() throws {
        let channel = FakeChannel(linkTransport: .lan)
        let store = MemoryPairingStore(secrets: [Vectors.hostId: Vectors.secret])
        let (session, _, _) = Fixtures.makeSession(channel: channel, store: store)

        session.handle(Fixtures.hello(transport: .lan))

        let ack: HelloAck = try XCTUnwrap(channel.firstFrame(ofType: .helloAck)).decode()
        XCTAssertTrue(ack.paired)
        XCTAssertTrue(ack.authRequired)
        XCTAssertEqual(session.state, .authenticating)
        XCTAssertNil(channel.firstFrame(ofType: .pairRequired))

        session.handle(try Frame.json(.auth, AuthMessage(proof: Vectors.authProof)))
        let authOK: AuthOK = try XCTUnwrap(channel.firstFrame(ofType: .authOK)).decode()
        XCTAssertEqual(authOK.proof.hexString, Vectors.authAckProof.hexString)
    }

    func testEncryptionIsNotEnabledWhenTheHostOptsOut() throws {
        let channel = FakeChannel(linkTransport: .lan)
        let store = MemoryPairingStore(secrets: [Vectors.hostId: Vectors.secret])
        let (session, _, _) = Fixtures.makeSession(channel: channel, store: store)

        session.handle(Fixtures.hello(transport: .lan, encrypt: false))
        session.handle(try Frame.json(.auth, AuthMessage(proof: Vectors.authProof)))

        XCTAssertNil(channel.encryptionKeys)
        XCTAssertEqual(session.state, .configuring)
    }

    func testBadAuthProofFailsAndCloses() throws {
        let channel = FakeChannel(linkTransport: .lan)
        let store = MemoryPairingStore(secrets: [Vectors.hostId: Vectors.secret])
        let (session, delegate, _) = Fixtures.makeSession(channel: channel, store: store)

        session.handle(Fixtures.hello(transport: .lan))
        session.handle(try Frame.json(.auth, AuthMessage(proof: Data(repeating: 0xEE, count: 32))))

        XCTAssertNotNil(channel.firstFrame(ofType: .authFail))
        XCTAssertTrue(channel.isClosed)
        XCTAssertEqual(channel.closeReasons, [nil], "AUTH_FAIL replaces BYE")
        XCTAssertEqual(delegate.endReasons.count, 1)
        // The stored secret survives: the host may re-pair, the receiver forgets nothing.
        XCTAssertEqual(store.secret(forHost: Vectors.hostId), Vectors.secret)
    }

    // MARK: - PIN attempt limiting

    func testThreeWrongPINsLockAndRotateTheCode() throws {
        let channel = FakeChannel(linkTransport: .lan)
        var generated = ["123456", "654321"]
        let configuration = ReceiverSession.Configuration(
            descriptorProvider: { Fixtures.descriptor() },
            pairingStore: MemoryPairingStore(),
            pinGenerator: { generated.isEmpty ? "000000" : generated.removeFirst() },
            secretGenerator: { Vectors.secret },
            nonceGenerator: { Vectors.deviceNonce })
        let session = ReceiverSession(channel: channel, configuration: configuration)
        let delegate = RecordingSessionDelegate()
        session.delegate = delegate

        session.handle(Fixtures.hello(transport: .lan))
        XCTAssertEqual(session.state, .pairing(pin: "123456", attemptsLeft: 3))

        let wrong = try Frame.json(.pair, PairMessage(proof: Data(repeating: 0x00, count: 32)))

        session.handle(wrong)
        XCTAssertEqual(session.state, .pairing(pin: "123456", attemptsLeft: 2))
        session.handle(wrong)
        XCTAssertEqual(session.state, .pairing(pin: "123456", attemptsLeft: 1))
        session.handle(wrong)

        let failures = channel.frames(ofType: .pairFail).map { try! $0.decode(PairFail.self) }
        XCTAssertEqual(failures.map(\.attemptsLeft), [2, 1, 0])
        XCTAssertEqual(failures.map(\.locked), [false, false, true])
        XCTAssertEqual(delegate.pairingFailures, [2, 1, 0])
        XCTAssertTrue(channel.isClosed)
        XCTAssertEqual(channel.closeReasons, ["too many pairing attempts"])
        XCTAssertEqual(generated, [], "the PIN is rotated after the third failure")

        // Further frames after the lockout are ignored.
        session.handle(try Frame.json(.pair, PairMessage(proof: Vectors.pairProof)))
        XCTAssertNil(channel.firstFrame(ofType: .pairOK))
    }

    func testCorrectPINAfterTwoFailuresStillPairs() throws {
        let channel = FakeChannel(linkTransport: .lan)
        let store = MemoryPairingStore()
        let (session, _, _) = Fixtures.makeSession(channel: channel, store: store)

        session.handle(Fixtures.hello(transport: .lan))
        let wrong = try Frame.json(.pair, PairMessage(proof: Data(repeating: 0x00, count: 32)))
        session.handle(wrong)
        session.handle(wrong)
        session.handle(try Frame.json(.pair, PairMessage(proof: Vectors.pairProof)))

        XCTAssertNotNil(channel.firstFrame(ofType: .pairOK))
        XCTAssertFalse(channel.isClosed)
        XCTAssertEqual(store.secret(forHost: Vectors.hostId), Vectors.secret)
    }

    // MARK: - Transport hardening

    func testNonLoopbackPeerCannotClaimTheUnauthenticatedUSBPath() throws {
        let channel = FakeChannel(linkTransport: .lan)
        let (session, _, _) = Fixtures.makeSession(channel: channel)

        // A Mac on the network claiming "usb" must still authenticate.
        session.handle(Fixtures.hello(transport: .usb))

        let ack: HelloAck = try XCTUnwrap(channel.firstFrame(ofType: .helloAck)).decode()
        XCTAssertTrue(ack.authRequired)
        XCTAssertEqual(session.effectiveTransport, .lan)
        XCTAssertNotNil(channel.firstFrame(ofType: .pairRequired))
    }

    // MARK: - Protocol errors

    func testMalformedHelloClosesTheConnection() {
        let channel = FakeChannel(linkTransport: .usb)
        let (session, _, _) = Fixtures.makeSession(channel: channel)

        session.handle(Frame(type: .hello, payload: Data("not json".utf8)))

        XCTAssertTrue(channel.isClosed)
        XCTAssertEqual(channel.closeReasons, ["malformed HELLO"])
    }

    func testShortHostNonceIsRejected() throws {
        let channel = FakeChannel(linkTransport: .usb)
        let (session, _, _) = Fixtures.makeSession(channel: channel)

        session.handle(Fixtures.hello(transport: .usb, hostNonce: Data(repeating: 0x01, count: 8)))

        XCTAssertTrue(channel.isClosed)
        XCTAssertEqual(channel.closeReasons, ["bad hostNonce"])
    }

    func testStreamConfigBeforeHelloIsRejected() {
        let channel = FakeChannel(linkTransport: .usb)
        let (session, _, _) = Fixtures.makeSession(channel: channel)

        session.handle(Fixtures.streamConfig())

        XCTAssertTrue(channel.isClosed)
        XCTAssertNil(channel.firstFrame(ofType: .ready))
    }

    func testUnknownDirectionFramesAreIgnored() {
        let channel = FakeChannel(linkTransport: .usb)
        let (session, _, _) = Fixtures.makeSession(channel: channel)
        session.handle(Fixtures.hello(transport: .usb))
        session.handle(Fixtures.streamConfig())

        // KEYFRAME_REQUEST is R→H; receiving one must not disturb the session.
        session.handle(Frame(type: .keyframeRequest))

        XCTAssertEqual(session.state, .streaming)
        XCTAssertFalse(channel.isClosed)
    }

    func testSecondStreamConfigReconfiguresTheDecoder() throws {
        let channel = FakeChannel(linkTransport: .usb)
        let (session, _, sink) = Fixtures.makeSession(channel: channel)
        session.handle(Fixtures.hello(transport: .usb))
        session.handle(Fixtures.streamConfig(codec: .hevc, w: 2556, h: 1179))
        session.handle(Fixtures.streamConfig(codec: .h264, w: 1920, h: 1080))

        XCTAssertEqual(sink.configurations.count, 2)
        XCTAssertEqual(sink.configurations.last?.codec, .h264)
        XCTAssertEqual(sink.configurations.last?.wPx, 1920)
        XCTAssertEqual(channel.frames(ofType: .ready).count, 2)
    }

    func testMalformedVideoAsksForAKeyframe() {
        let channel = FakeChannel(linkTransport: .usb)
        let (session, _, sink) = Fixtures.makeSession(channel: channel)
        session.handle(Fixtures.hello(transport: .usb))
        session.handle(Fixtures.streamConfig())

        session.handle(Frame(type: .video, payload: Data([0x01, 0x02])))

        XCTAssertTrue(sink.frames.isEmpty)
        XCTAssertEqual(channel.frames(ofType: .keyframeRequest).count, 1)
    }

    func testConnectionDropResetsTheSink() {
        let channel = FakeChannel(linkTransport: .usb)
        let (session, delegate, sink) = Fixtures.makeSession(channel: channel)
        session.handle(Fixtures.hello(transport: .usb))
        session.handle(Fixtures.streamConfig())

        session.connectionClosed(reason: "peer closed the connection")

        XCTAssertEqual(session.state, .closed("peer closed the connection"))
        XCTAssertEqual(sink.resetCount, 1)
        XCTAssertEqual(delegate.endReasons, ["peer closed the connection"])
    }
}
