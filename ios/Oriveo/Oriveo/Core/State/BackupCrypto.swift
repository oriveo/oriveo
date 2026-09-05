import Foundation
import CryptoKit
import CommonCrypto

enum BackupCrypto {
    static let pbkdf2Iterations: UInt32 = 600_000
    static let saltLength = 16
    static let nonceLength = 12


    static func encrypt(_ plaintext: Data, password: String) throws -> Data {
        let salt = try generateRandomBytes(count: saltLength)
        let key = try deriveKey(password: password, salt: salt)
        let nonce = try AES.GCM.Nonce(data: generateRandomBytes(count: nonceLength))
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)

        var result = Data()
        result.append(salt)
        result.append(contentsOf: sealed.nonce)
        result.append(sealed.ciphertext)
        result.append(sealed.tag)
        return result
    }


    static func decrypt(_ encrypted: Data, password: String) throws -> Data {
        let minSize = saltLength + nonceLength + 16
        guard encrypted.count >= minSize else {
            throw BackupError.invalidEncryptedData
        }

        let salt = encrypted.prefix(saltLength)
        let nonceRange = saltLength..<(saltLength + nonceLength)
        let nonce = try AES.GCM.Nonce(data: encrypted[nonceRange])

        let ciphertextAndTag = encrypted[(saltLength + nonceLength)...]
        let tagStart = ciphertextAndTag.endIndex - 16
        let ciphertext = ciphertextAndTag[ciphertextAndTag.startIndex..<tagStart]
        let tag = ciphertextAndTag[tagStart...]

        let key = try deriveKey(password: password, salt: Data(salt))
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(sealedBox, using: key)
    }


    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derivedKey = Data(count: 32) // 256 bits

        let status = derivedKey.withUnsafeMutableBytes { derivedKeyPtr in
            salt.withUnsafeBytes { saltPtr in
                passwordData.withUnsafeBytes { passwordPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        derivedKeyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }

        guard status == kCCSuccess else { throw BackupError.keyDerivationFailed }
        return SymmetricKey(data: derivedKey)
    }

    private static func generateRandomBytes(count: Int) throws -> Data {
        var bytes = Data(count: count)
        let result = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard result == errSecSuccess else { throw BackupError.encryptionFailed }
        return bytes
    }
}
