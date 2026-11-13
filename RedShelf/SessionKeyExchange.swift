import CryptoKit
import Foundation

/// One request-scoped X25519 exchange. The private key is never persisted.
struct SessionKeyExchange {
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let serverPublicKey: Curve25519.KeyAgreement.PublicKey

    init(serverPublicKey: Data? = nil) throws {
        guard let raw = serverPublicKey ?? Data(base64Encoded: "Kr0iygsCu3inYJNXCL4k4JuzaYQ2afI1xbwc7BH6sm8=") else { throw FeedError.invalidResponse }
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
        self.serverPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
    }

    var publicKeyBase64: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }

    func decrypt(_ value: String) throws -> Data {
        guard let encrypted = Data(base64Encoded: value), encrypted.count >= 28 else { throw FeedError.invalidResponse }
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: serverPublicKey)
        let key = secret.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        let nonce = try AES.GCM.Nonce(data: encrypted.prefix(12))
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: encrypted.dropFirst(12).dropLast(16), tag: encrypted.suffix(16))
        let plaintext = try AES.GCM.open(sealed, using: key)
        guard plaintext.count >= 32 else { throw FeedError.invalidResponse }
        return plaintext
    }
}
