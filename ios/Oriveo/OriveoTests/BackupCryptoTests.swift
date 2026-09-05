import Testing
import Foundation
@testable import Oriveo


@Suite("BackupCrypto")
struct BackupCryptoTests {


    @Test("Encrypt Decrypt Roundtrip")
    func encryptDecryptRoundtrip() throws {
        let plaintext = Data("Hello, Oriveo backup!".utf8)
        let password = "test-password-123"

        let encrypted = try BackupCrypto.encrypt(plaintext, password: password)
        let decrypted = try BackupCrypto.decrypt(encrypted, password: password)

        #expect(decrypted == plaintext)
    }

    @Test("Encrypt Decrypt Empty Data")
    func encryptDecryptEmptyData() throws {
        let plaintext = Data()
        let password = "password12345678"

        let encrypted = try BackupCrypto.encrypt(plaintext, password: password)
        let decrypted = try BackupCrypto.decrypt(encrypted, password: password)

        #expect(decrypted == plaintext)
    }

    @Test("Encrypt Decrypt Large Data")
    func encryptDecryptLargeData() throws {
        let keys = (0..<50).map { i in
            """
            {"providerID":"uuid-\(i)","apiKey":"sk-very-long-api-key-\(i)-\(String(repeating: "x", count: 100))","apiKeyPreview":"sk-...\(i)"}
            """
        }
        let json = "{\"keys\":[\(keys.joined(separator: ","))]}"
        let plaintext = Data(json.utf8)
        let password = "strong-password!"

        let encrypted = try BackupCrypto.encrypt(plaintext, password: password)
        let decrypted = try BackupCrypto.decrypt(encrypted, password: password)

        #expect(decrypted == plaintext)
    }


    @Test("Wrong Password Fails")
    func wrongPasswordFails() throws {
        let plaintext = Data("secret data".utf8)
        let encrypted = try BackupCrypto.encrypt(plaintext, password: "correct-password")

        #expect(throws: (any Error).self) {
            _ = try BackupCrypto.decrypt(encrypted, password: "wrong-password")
        }
    }

    @Test("Similar Password Fails")
    func similarPasswordFails() throws {
        let plaintext = Data("secret data".utf8)
        let encrypted = try BackupCrypto.encrypt(plaintext, password: "MyPassword123")

        #expect(throws: (any Error).self) {
            _ = try BackupCrypto.decrypt(encrypted, password: "MyPassword124")
        }
    }


    @Test("Encrypted Data Minimum Size")
    func encryptedDataMinimumSize() throws {
        let plaintext = Data("x".utf8)
        let encrypted = try BackupCrypto.encrypt(plaintext, password: "password")

        #expect(encrypted.count >= 16 + 12 + 1 + 16)
    }

    @Test("Different Encryption Each Time")
    func differentEncryptionEachTime() throws {
        let plaintext = Data("same data".utf8)
        let password = "same-password"

        let enc1 = try BackupCrypto.encrypt(plaintext, password: password)
        let enc2 = try BackupCrypto.encrypt(plaintext, password: password)

        #expect(enc1 != enc2)
    }

    @Test("Truncated Data Rejected")
    func truncatedDataRejected() throws {
        let plaintext = Data("test".utf8)
        let encrypted = try BackupCrypto.encrypt(plaintext, password: "password")

        let truncated = encrypted.prefix(10)
        #expect(throws: BackupError.self) {
            _ = try BackupCrypto.decrypt(Data(truncated), password: "password")
        }
    }


    @Test("Chinese Password Works")
    func chinesePasswordWorks() throws {
        let plaintext = Data("api key data".utf8)
        let password = "ひみつのかぎ！"

        let encrypted = try BackupCrypto.encrypt(plaintext, password: password)
        let decrypted = try BackupCrypto.decrypt(encrypted, password: password)

        #expect(decrypted == plaintext)
    }

    @Test("Emoji Password Works")
    func emojiPasswordWorks() throws {
        let plaintext = Data("test".utf8)
        let password = "🔑🐾🎉secure"

        let encrypted = try BackupCrypto.encrypt(plaintext, password: password)
        let decrypted = try BackupCrypto.decrypt(encrypted, password: password)

        #expect(decrypted == plaintext)
    }
}
