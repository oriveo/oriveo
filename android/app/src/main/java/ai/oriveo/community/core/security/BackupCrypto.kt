package ai.oriveo.community.core.security

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

object BackupCrypto {

    private const val PBKDF2_ITERATIONS = 600_000
    private const val SALT_LENGTH = 16
    private const val NONCE_LENGTH = 12
    private const val KEY_LENGTH_BITS = 256
    private const val GCM_TAG_LENGTH_BITS = 128
    private const val MIN_PASSWORD_LENGTH = 8

    fun encrypt(data: ByteArray, password: String): ByteArray {
        require(password.length >= MIN_PASSWORD_LENGTH) { "Password must be at least $MIN_PASSWORD_LENGTH characters" }

        val random = SecureRandom()

        val salt = ByteArray(SALT_LENGTH).also { random.nextBytes(it) }
        val nonce = ByteArray(NONCE_LENGTH).also { random.nextBytes(it) }
        val key = deriveKey(password, salt)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(GCM_TAG_LENGTH_BITS, nonce))
        val ciphertextWithTag = cipher.doFinal(data)

        // salt + nonce + (ciphertext || tag)
        return salt + nonce + ciphertextWithTag
    }

    fun decrypt(data: ByteArray, password: String): ByteArray {
        require(password.length >= MIN_PASSWORD_LENGTH) { "Password must be at least $MIN_PASSWORD_LENGTH characters" }

        val minSize = SALT_LENGTH + NONCE_LENGTH + GCM_TAG_LENGTH_BITS / 8
        require(data.size >= minSize) { "Encrypted data too short" }

        val salt = data.copyOfRange(0, SALT_LENGTH)
        val nonce = data.copyOfRange(SALT_LENGTH, SALT_LENGTH + NONCE_LENGTH)
        val ciphertextWithTag = data.copyOfRange(SALT_LENGTH + NONCE_LENGTH, data.size)

        val key = deriveKey(password, salt)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_LENGTH_BITS, nonce))
        return cipher.doFinal(ciphertextWithTag)
    }

    private fun deriveKey(password: String, salt: ByteArray): SecretKeySpec {
        val spec = PBEKeySpec(password.toCharArray(), salt, PBKDF2_ITERATIONS, KEY_LENGTH_BITS)
        val factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        val keyBytes = factory.generateSecret(spec).encoded
        return SecretKeySpec(keyBytes, "AES")
    }
}
