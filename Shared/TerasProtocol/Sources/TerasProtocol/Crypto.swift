import Foundation
import CryptoKit

/// Pairing and session crypto exactly as in PROTOCOL §2.1 and §3.3.
public enum TerasCrypto {
    public static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return d
    }

    /// pinKey = SHA256(pin ‖ deviceId ‖ hostId)
    public static func pinKey(pin: String, deviceId: String, hostId: String) -> Data {
        var m = Data()
        m.append(Data(pin.utf8)); m.append(Data(deviceId.utf8)); m.append(Data(hostId.utf8))
        return Data(SHA256.hash(data: m))
    }

    private static func hmac(key: Data, label: String, hostNonce: Data, deviceNonce: Data) -> Data {
        var m = Data(label.utf8)
        m.append(hostNonce); m.append(deviceNonce)
        return Data(HMAC<SHA256>.authenticationCode(for: m, using: SymmetricKey(data: key)))
    }

    public static func pairProof(pinKey: Data, hostNonce: Data, deviceNonce: Data) -> Data {
        hmac(key: pinKey, label: "pair", hostNonce: hostNonce, deviceNonce: deviceNonce)
    }
    public static func authProof(secret: Data, hostNonce: Data, deviceNonce: Data) -> Data {
        hmac(key: secret, label: "auth", hostNonce: hostNonce, deviceNonce: deviceNonce)
    }
    public static func authAckProof(secret: Data, hostNonce: Data, deviceNonce: Data) -> Data {
        hmac(key: secret, label: "auth-ack", hostNonce: hostNonce, deviceNonce: deviceNonce)
    }

    public static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    static func hkdf(_ ikm: Data, salt: Data, info: String, count: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt,
                                         info: Data(info.utf8), outputByteCount: count)
        return key.withUnsafeBytes { Data($0) }
    }

    /// PAIR_OK box = AES‑256‑GCM(key = HKDF(pinKey, salt, "teras-v1-pairbox"), nonce = 12 zero bytes, secret) → ciphertext ‖ tag
    public static func sealPairBox(secret: Data, pinKey: Data, hostNonce: Data, deviceNonce: Data) throws -> Data {
        let key = hkdf(pinKey, salt: hostNonce + deviceNonce, info: "teras-v1-pairbox", count: 32)
        let nonce = try AES.GCM.Nonce(data: Data(count: 12))
        let box = try AES.GCM.seal(secret, using: SymmetricKey(data: key), nonce: nonce)
        return box.ciphertext + box.tag
    }

    public static func openPairBox(_ box: Data, pinKey: Data, hostNonce: Data, deviceNonce: Data) throws -> Data {
        guard box.count == 32 + 16 else { throw CryptoError.badBox }
        let key = hkdf(pinKey, salt: hostNonce + deviceNonce, info: "teras-v1-pairbox", count: 32)
        let nonce = try AES.GCM.Nonce(data: Data(count: 12))
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: box.prefix(32), tag: box.suffix(16))
        return try AES.GCM.open(sealed, using: SymmetricKey(data: key))
    }

    public static func sessionKeys(secret: Data, hostNonce: Data, deviceNonce: Data) -> (h2r: Data, r2h: Data) {
        let salt = hostNonce + deviceNonce
        return (hkdf(secret, salt: salt, info: "teras-v1-h2r", count: 32),
                hkdf(secret, salt: salt, info: "teras-v1-r2h", count: 32))
    }

    /// 6-digit PIN with leading zeros allowed.
    public static func generatePIN() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}

public enum CryptoError: Error, Equatable {
    case badBox
    case counterNotIncreasing
    case badEnvelope
}

/// AES‑256‑GCM envelope (PROTOCOL §2.1). One instance per direction.
public final class SessionCipher {
    private let key: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var lastReceivedCounter: UInt64? = nil
    private static let aad = Data([FrameType.enc.rawValue])

    public init(key: Data) { self.key = SymmetricKey(data: key) }

    private static func nonce(_ counter: UInt64) -> Data {
        var d = Data(count: 4); d.appendUInt64(counter); return d
    }

    /// Wrap a plaintext frame into an ENC frame.
    public func seal(_ frame: Frame) throws -> Frame {
        let counter = sendCounter
        sendCounter += 1
        var plain = Data(capacity: 1 + frame.payload.count)
        plain.append(frame.type.rawValue); plain.append(frame.payload)
        let box = try AES.GCM.seal(plain, using: key, nonce: try AES.GCM.Nonce(data: Self.nonce(counter)),
                                   authenticating: Self.aad)
        var payload = Data(capacity: 8 + box.ciphertext.count + 16)
        payload.appendUInt64(counter); payload.append(box.ciphertext); payload.append(box.tag)
        return Frame(type: .enc, payload: payload)
    }

    /// Unwrap an ENC frame. Throws if the counter is not strictly increasing or the tag fails.
    public func open(_ frame: Frame) throws -> Frame {
        guard frame.type == .enc, frame.payload.count >= 8 + 16 + 1 else { throw CryptoError.badEnvelope }
        let counter = frame.payload.readUInt64(at: frame.payload.startIndex)
        if let last = lastReceivedCounter, counter <= last { throw CryptoError.counterNotIncreasing }
        let body = frame.payload.dropFirst(8)
        let ciphertext = body.dropLast(16)
        let tag = body.suffix(16)
        let sealed = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: Self.nonce(counter)),
                                           ciphertext: ciphertext, tag: tag)
        let plain = try AES.GCM.open(sealed, using: key, authenticating: Self.aad)
        guard let first = plain.first, let type = FrameType(rawValue: first) else { throw CryptoError.badEnvelope }
        lastReceivedCounter = counter
        return Frame(type: type, payload: plain.dropFirst())
    }
}
