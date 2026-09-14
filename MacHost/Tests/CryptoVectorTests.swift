import XCTest
import TerasProtocol
@testable import TerasCore

/// Guards the interop vectors in docs/VECTORS.md. If one of these changes, the
/// iOS and Android receivers stop being able to pair with this host.
final class CryptoVectorTests: XCTestCase {

    func testPinKeyMatchesVector() {
        let pinKey = TerasCrypto.pinKey(pin: Fixtures.pin, deviceId: Fixtures.deviceId, hostId: Fixtures.hostId)
        XCTAssertEqual(pinKey.hexString, "3331a1a8f74fce2199865a288920415bdc45ec25f0cea4de51de6fb64ec86f7a")
    }

    func testProofsMatchVectors() {
        let pinKey = TerasCrypto.pinKey(pin: Fixtures.pin, deviceId: Fixtures.deviceId, hostId: Fixtures.hostId)

        XCTAssertEqual(TerasCrypto.pairProof(pinKey: pinKey,
                                              hostNonce: Fixtures.hostNonce,
                                              deviceNonce: Fixtures.deviceNonce).hexString,
                       "110062869395c85646afbcf6e8de85c902b69c610c2d469d7fa471763d59d690")

        XCTAssertEqual(TerasCrypto.authProof(secret: Fixtures.secret,
                                              hostNonce: Fixtures.hostNonce,
                                              deviceNonce: Fixtures.deviceNonce).hexString,
                       "d68dfc86e14f407a12db80aa5d552db1c3085d01aa2964a0cfa6dcb6c788f76f")

        XCTAssertEqual(TerasCrypto.authAckProof(secret: Fixtures.secret,
                                                 hostNonce: Fixtures.hostNonce,
                                                 deviceNonce: Fixtures.deviceNonce).hexString,
                       "a72b55ef64bc87c44e8a798addb5ba7600e9491d8275c47166fd47fddaf28bce")
    }

    func testPairBoxMatchesVectorAndOpens() throws {
        let pinKey = TerasCrypto.pinKey(pin: Fixtures.pin, deviceId: Fixtures.deviceId, hostId: Fixtures.hostId)
        let box = try TerasCrypto.sealPairBox(secret: Fixtures.secret,
                                               pinKey: pinKey,
                                               hostNonce: Fixtures.hostNonce,
                                               deviceNonce: Fixtures.deviceNonce)
        XCTAssertEqual(box.count, 48)
        XCTAssertEqual(box.hexString,
                       "bdfc8dab9bb85daa7ce0e5d24f9c9bc5f9b2196e81fb06c488aa19e226033eb4e46a8cf8ffdf2709115fb9e0361ec2c8")

        let recovered = try TerasCrypto.openPairBox(box,
                                                     pinKey: pinKey,
                                                     hostNonce: Fixtures.hostNonce,
                                                     deviceNonce: Fixtures.deviceNonce)
        XCTAssertEqual(recovered, Fixtures.secret)
    }

    func testSessionKeysMatchVectors() {
        let keys = TerasCrypto.sessionKeys(secret: Fixtures.secret,
                                            hostNonce: Fixtures.hostNonce,
                                            deviceNonce: Fixtures.deviceNonce)
        XCTAssertEqual(keys.h2r.hexString, "2be1636a55b023d61f070f8d225e48be67fccf9721773695b73c5410b4d9cd26")
        XCTAssertEqual(keys.r2h.hexString, "65aaf0ab94238a685aa8aa78efddaf2272ba0257782653cfacd1366749283e90")
    }

    func testEncryptedPingFrameMatchesVector() throws {
        let keys = TerasCrypto.sessionKeys(secret: Fixtures.secret,
                                            hostNonce: Fixtures.hostNonce,
                                            deviceNonce: Fixtures.deviceNonce)
        let cipher = SessionCipher(key: keys.h2r)
        let sealed = try cipher.seal(Frame(type: .ping, payload: Data(count: 8)))
        XCTAssertEqual(sealed.encoded().hexString,
                       "000000227f0000000000000000f3e9dbdfa6cd92ca16e0af990c67a364bab8f7cb499d477913")
    }

    func testEnvelopeRoundTripAndCounterOrdering() throws {
        let keys = TerasCrypto.sessionKeys(secret: Fixtures.secret,
                                            hostNonce: Fixtures.hostNonce,
                                            deviceNonce: Fixtures.deviceNonce)
        let sender = SessionCipher(key: keys.h2r)
        let receiver = SessionCipher(key: keys.h2r)

        let first = try sender.seal(Frame(type: .ping, payload: Data([1, 2, 3])))
        let second = try sender.seal(Frame(type: .keyframeRequest))

        XCTAssertEqual(try receiver.open(first).payload, Data([1, 2, 3]))
        XCTAssertEqual(try receiver.open(second).type, .keyframeRequest)
        // A replay reuses a counter that is no longer strictly increasing.
        XCTAssertThrowsError(try receiver.open(second))
    }
}
