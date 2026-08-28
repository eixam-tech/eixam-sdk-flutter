package dev.eixam.connect.flutter.storage

import java.security.KeyStoreException
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class SecureStorageFailureClassifierTest {
    @Test
    fun malformedBase64IsEntryUnreadable() {
        val error = assertThrows(SecureStorageEntryUnreadableException::class.java) {
            SecureStoragePayloadCodec.decrypt(
                "not-base64:still-not-base64",
                generateKey(),
                Base64.getDecoder()::decode,
            )
        }

        assertEquals(
            SecureStorageErrorCodes.entryUnreadable,
            SecureStorageFailureClassifier.codeFor(error),
        )
    }

    @Test
    fun authenticatedDecryptionFailureIsEntryUnreadable() {
        val encoded = encrypt("persisted-session", generateKey())

        val error = assertThrows(SecureStorageEntryUnreadableException::class.java) {
            SecureStoragePayloadCodec.decrypt(
                encoded,
                generateKey(),
                Base64.getDecoder()::decode,
            )
        }

        assertEquals(
            SecureStorageErrorCodes.entryUnreadable,
            SecureStorageFailureClassifier.codeFor(error),
        )
    }

    @Test
    fun keystoreFailureRemainsUnavailable() {
        assertEquals(
            SecureStorageErrorCodes.unavailable,
            SecureStorageFailureClassifier.codeFor(KeyStoreException()),
        )
    }

    @Test
    fun writeFailureRemainsDistinct() {
        assertEquals(
            SecureStorageErrorCodes.writeFailed,
            SecureStorageFailureClassifier.codeFor(SecureStorageWriteFailedException()),
        )
    }

    @Test
    fun deleteFailureRemainsDistinct() {
        assertEquals(
            SecureStorageErrorCodes.deleteFailed,
            SecureStorageFailureClassifier.codeFor(SecureStorageDeleteFailedException()),
        )
    }

    private fun generateKey() = KeyGenerator.getInstance("AES").apply {
        init(256)
    }.generateKey()

    private fun encrypt(value: String, key: javax.crypto.SecretKey): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        return Base64.getEncoder().encodeToString(cipher.iv) + ":" +
            Base64.getEncoder().encodeToString(ciphertext)
    }
}
