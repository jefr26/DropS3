import Foundation
import CryptoKit
import CommonCrypto

/// Key material for one snapshot: master key derived from the passphrase with a per-snapshot salt.
struct Encryption: Sendable {
    let master: SymmetricKey
    let salt: Data
}

/// Encrypted file format (self-contained, so any single object can be decrypted with the passphrase):
///   "RSPDENC1" (8) · PBKDF2 salt (16) · file salt (32) · chunks
/// Each chunk is up to 1 MiB of plaintext sealed with AES-256-GCM (ciphertext + 16-byte tag).
/// File key = HKDF-SHA256(master, file salt). Nonce = chunk counter + "final chunk" flag,
/// so reordered, dropped or truncated chunks fail authentication.
enum Crypto {
    static let magic = Data("RSPDENC1".utf8)
    static let chunkSize = 1 << 20
    static let tagSize = 16
    static let iterations: UInt32 = 600_000

    struct CryptoError: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    /// PBKDF2-HMAC-SHA256, 600k iterations.
    static func deriveMaster(passphrase: String, salt: Data) throws -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let length = passphrase.utf8.count
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passphrase, length,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &out, out.count)
        }
        guard status == kCCSuccess else { throw CryptoError(text: t("No se pudo derivar la clave de cifrado.", "Couldn't derive the encryption key.")) }
        return SymmetricKey(data: Data(out))
    }

    private static func fileKey(_ master: SymmetricKey, _ fileSalt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: fileSalt, info: Data("respaldo-file-v1".utf8), outputByteCount: 32)
    }

    private static func nonce(_ counter: UInt64, final: Bool) -> AES.GCM.Nonce {
        var bytes = Data(count: 3)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        bytes.append(final ? 1 : 0)
        return try! AES.GCM.Nonce(data: bytes)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Encrypts `source` into `destination`. Returns SHA-256 and size of the plaintext.
    static func encryptFile(from source: URL, to destination: URL, encryption: Encryption) throws -> (sha256: String, size: Int64) {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        let fileSalt = randomBytes(32)
        let key = fileKey(encryption.master, fileSalt)
        try output.write(contentsOf: magic + encryption.salt + fileSalt)

        var sha = SHA256()
        var size: Int64 = 0
        var counter: UInt64 = 0
        var current = try input.read(upToCount: chunkSize) ?? Data()
        while true {
            let finished: Bool = try autoreleasepool {
                let next = try input.read(upToCount: chunkSize) ?? Data()
                let final = next.isEmpty
                sha.update(data: current)
                size += Int64(current.count)
                let box = try AES.GCM.seal(current, using: key, nonce: nonce(counter, final: final))
                try output.write(contentsOf: box.ciphertext + box.tag)
                counter += 1
                current = next
                return final
            }
            if finished { break }
        }
        return (hex(sha.finalize()), size)
    }

    /// Decrypts `source` into `destination`. Returns SHA-256 and size of the recovered plaintext.
    static func decryptFile(from source: URL, to destination: URL, keys: KeyCache) throws -> (sha256: String, size: Int64) {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard let header = try input.read(upToCount: 56), header.count == 56, header.prefix(8) == magic else {
            throw CryptoError(text: t("El archivo no tiene el formato cifrado esperado.", "The file is not in the expected encrypted format."))
        }
        let master = try keys.master(for: Data(header[8..<24]))
        let key = fileKey(master, Data(header[24..<56]))

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var sha = SHA256()
        var size: Int64 = 0
        var counter: UInt64 = 0
        let sealedSize = chunkSize + tagSize
        var current = try input.read(upToCount: sealedSize) ?? Data()
        while true {
            let finished: Bool = try autoreleasepool {
                guard current.count >= tagSize else { throw CryptoError(text: t("Archivo cifrado truncado.", "Encrypted file is truncated.")) }
                let next = try input.read(upToCount: sealedSize) ?? Data()
                let final = next.isEmpty
                let box = try AES.GCM.SealedBox(nonce: nonce(counter, final: final),
                                                ciphertext: current.dropLast(tagSize), tag: current.suffix(tagSize))
                let plain: Data
                do { plain = try AES.GCM.open(box, using: key) } catch {
                    throw CryptoError(text: t("No se pudo descifrar: clave incorrecta o datos dañados.", "Couldn't decrypt: wrong passphrase or damaged data."))
                }
                sha.update(data: plain)
                size += Int64(plain.count)
                try output.write(contentsOf: plain)
                counter += 1
                current = next
                return final
            }
            if finished { break }
        }
        return (hex(sha.finalize()), size)
    }
}

/// Derives (and caches) the master key per PBKDF2 salt, since derivation is deliberately slow.
final class KeyCache: @unchecked Sendable {
    private let passphrase: String
    private var cache: [Data: SymmetricKey] = [:]
    private let lock = NSLock()

    init(passphrase: String) { self.passphrase = passphrase }

    func master(for salt: Data) throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let key = cache[salt] { return key }
        guard !passphrase.isEmpty else { throw Crypto.CryptoError(text: t("Falta la clave de cifrado.", "The encryption passphrase is missing.")) }
        let key = try Crypto.deriveMaster(passphrase: passphrase, salt: salt)
        cache[salt] = key
        return key
    }
}
