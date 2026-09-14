import XCTest
import TandemProtocol
@testable import TandemCore

/// Guards the interop vectors in docs/VECTORS.md. If one of these changes, the
/// iOS and Android receivers stop being able to pair with this host.
final class CryptoVectorTests: XCTestCase {

    func testPinKeyMatchesVector() {
        let pinKey = TandemCrypto.pinKey(pin: Fixtures.pin, deviceId: Fixtures.deviceId, hostId: Fixtures.hostId)
        XCTAssertEqual(pinKey.hexString, "3331a1a8f74fce2199865a288920415bdc45ec25f0cea4de51de6fb64ec86f7a")
    }

    func testProofsMatchVectors() {
        let pinKey = TandemCrypto.pinKey(pin: Fixtures.pin, deviceId: Fixtures.deviceId, hostId: Fixtures.hostId)

        XCTAssertEqual(TandemCrypto.pairProof(pinKey: pinKey,
                                              hostNonce: Fixtures.hostNonce,
                                              deviceNonce: Fixtures.deviceNonce).hexString,
                       "110062869395c85646afbcf6e8de85c902b69c610c2d469d7fa471763d59d690")

        XCTAssertEqual(TandemCrypto.authProof(secret: Fixtures.secret,
                                              hostNonce: Fixtures.hostNonce,
                                              deviceNonce: Fixtures.deviceNonce).hexString,
                       "d68dfc86e14f407a12db80aa5d552db1c3085d01aa2964a0cfa6dcb6c788f76f")

        XCTAssertEqual(TandemCrypto.authAckProof(secret: Fixtures.secret,
                                                 hostNonce: Fixtures.hostNonce,
                                                 deviceNonce: Fixtures.deviceNonce).hexString,
                       "a72b55ef64bc87c44e8a798addb5ba7600e9491d8275c47166fd47fddaf28bce")
    }

    func testPairBoxMatchesVectorAndOpens() throws {
        let pinKey = TandemCrypto.pinKey(pin: Fixtures.pin, deviceId: Fixtures.deviceId, hostId: Fixtures.hostId)
        let box = try TandemCrypto.sealPairBox(secret: Fixtures.secret,
                                               pinKey: pinKey,
                                               hostNonce: Fixtures.hostNonce,
                                               deviceNonce: Fixtures.deviceNonce)
        XCTAssertEqual(box.count, 48)
        XCTAssertEqual(box.hexString,
                       "c90c53edfb1a4127670fe4f4251631623bf295b96611fcc312263d578adb638f39d25d6dc150588a33b15bf4b7171304")

        let recovered = try TandemCrypto.openPairBox(box,
                                                     pinKey: pinKey,
                                                     hostNonce: Fixtures.hostNonce,
                                                     deviceNonce: Fixtures.deviceNonce)
        XCTAssertEqual(recovered, Fixtures.secret)
    }

    func testSessionKeysMatchVectors() {
        let keys = TandemCrypto.sessionKeys(secret: Fixtures.secret,
                                            hostNonce: Fixtures.hostNonce,
                                            deviceNonce: Fixtures.deviceNonce)
        XCTAssertEqual(keys.h2r.hexString, "91fbd9ebfbf64bd6d184081001ec015052beb69813a66c16df6880d7723f2cd6")
        XCTAssertEqual(keys.r2h.hexString, "42c14ebc49d6125a587031486fc377723ccb7869b44fa63950e53867ef15782c")
    }

    func testEncryptedPingFrameMatchesVector() throws {
        let keys = TandemCrypto.sessionKeys(secret: Fixtures.secret,
                                            hostNonce: Fixtures.hostNonce,
                                            deviceNonce: Fixtures.deviceNonce)
        let cipher = SessionCipher(key: keys.h2r)
        let sealed = try cipher.seal(Frame(type: .ping, payload: Data(count: 8)))
        XCTAssertEqual(sealed.encoded().hexString,
                       "000000227f00000000000000001438a7c6f82d55a7afa504d08df8c01785696299fb0e9aa7e7")
    }

    func testEnvelopeRoundTripAndCounterOrdering() throws {
        let keys = TandemCrypto.sessionKeys(secret: Fixtures.secret,
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
