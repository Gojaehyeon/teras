import XCTest
@testable import TandemProtocol

final class CryptoTests: XCTestCase {
    let hostId = "11111111-1111-1111-1111-111111111111"
    let deviceId = "22222222-2222-2222-2222-222222222222"
    let hostNonce = Data(repeating: 0x01, count: 16)
    let deviceNonce = Data(repeating: 0x02, count: 16)
    let secret = Data(repeating: 0x03, count: 32)

    func testPairFlow() throws {
        let pinKey = TandemCrypto.pinKey(pin: "123456", deviceId: deviceId, hostId: hostId)
        let proof = TandemCrypto.pairProof(pinKey: pinKey, hostNonce: hostNonce, deviceNonce: deviceNonce)
        XCTAssertEqual(proof.count, 32)
        let box = try TandemCrypto.sealPairBox(secret: secret, pinKey: pinKey, hostNonce: hostNonce, deviceNonce: deviceNonce)
        XCTAssertEqual(box.count, 48)
        XCTAssertEqual(try TandemCrypto.openPairBox(box, pinKey: pinKey, hostNonce: hostNonce, deviceNonce: deviceNonce), secret)
        XCTAssertThrowsError(try TandemCrypto.openPairBox(box, pinKey: TandemCrypto.pinKey(pin: "000000", deviceId: deviceId, hostId: hostId), hostNonce: hostNonce, deviceNonce: deviceNonce))
    }

    func testSessionCipherRoundTripAndReplay() throws {
        let keys = TandemCrypto.sessionKeys(secret: secret, hostNonce: hostNonce, deviceNonce: deviceNonce)
        XCTAssertNotEqual(keys.h2r, keys.r2h)
        let tx = SessionCipher(key: keys.h2r), rx = SessionCipher(key: keys.h2r)
        let f = Frame(type: .ping, payload: Data(count: 8))
        let e1 = try tx.seal(f), e2 = try tx.seal(f)
        XCTAssertEqual(try rx.open(e1), f)
        XCTAssertEqual(try rx.open(e2), f)
        XCTAssertThrowsError(try rx.open(e1)) // replay
        XCTAssertThrowsError(try SessionCipher(key: keys.r2h).open(e2)) // wrong key
    }

    /// Prints interop vectors (see docs/VECTORS.md) so the Android implementation can be checked byte-for-byte.
    func testPrintVectors() throws {
        let pinKey = TandemCrypto.pinKey(pin: "123456", deviceId: deviceId, hostId: hostId)
        let keys = TandemCrypto.sessionKeys(secret: secret, hostNonce: hostNonce, deviceNonce: deviceNonce)
        let enc = try SessionCipher(key: keys.h2r).seal(Frame(type: .ping, payload: Data(count: 8)))
        let box = try TandemCrypto.sealPairBox(secret: secret, pinKey: pinKey, hostNonce: hostNonce, deviceNonce: deviceNonce)
        let lines = [
            "pinKey \(pinKey.hex)",
            "pairProof \(TandemCrypto.pairProof(pinKey: pinKey, hostNonce: hostNonce, deviceNonce: deviceNonce).hex)",
            "authProof \(TandemCrypto.authProof(secret: secret, hostNonce: hostNonce, deviceNonce: deviceNonce).hex)",
            "authAckProof \(TandemCrypto.authAckProof(secret: secret, hostNonce: hostNonce, deviceNonce: deviceNonce).hex)",
            "pairBox \(box.hex)",
            "key_h2r \(keys.h2r.hex)",
            "key_r2h \(keys.r2h.hex)",
            "encFrame \(enc.encoded().hex)",
        ]
        print("VECTORS\n" + lines.joined(separator: "\n"))
    }
}

extension Data { var hex: String { map { String(format: "%02x", $0) }.joined() } }
