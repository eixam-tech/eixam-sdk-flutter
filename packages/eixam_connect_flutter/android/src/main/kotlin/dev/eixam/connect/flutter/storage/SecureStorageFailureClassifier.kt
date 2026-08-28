package dev.eixam.connect.flutter.storage

import java.nio.charset.StandardCharsets
import java.security.InvalidAlgorithmParameterException
import javax.crypto.AEADBadTagException
import javax.crypto.BadPaddingException
import javax.crypto.Cipher
import javax.crypto.IllegalBlockSizeException
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal object SecureStorageErrorCodes {
    const val entryUnreadable = "secure_storage_entry_unreadable"
    const val unavailable = "secure_storage_unavailable"
    const val writeFailed = "secure_storage_write_failed"
    const val deleteFailed = "secure_storage_delete_failed"
}

internal class SecureStorageEntryUnreadableException(cause: Throwable? = null) :
    Exception(cause)

internal class SecureStorageWriteFailedException(cause: Throwable? = null) :
    Exception(cause)

internal class SecureStorageDeleteFailedException(cause: Throwable? = null) :
    Exception(cause)

internal object SecureStorageFailureClassifier {
    fun codeFor(error: Throwable): String = when (error) {
        is SecureStorageEntryUnreadableException -> SecureStorageErrorCodes.entryUnreadable
        is SecureStorageWriteFailedException -> SecureStorageErrorCodes.writeFailed
        is SecureStorageDeleteFailedException -> SecureStorageErrorCodes.deleteFailed
        else -> SecureStorageErrorCodes.unavailable
    }
}

internal object SecureStoragePayloadCodec {
    private const val separator = ":"
    private const val gcmTagBits = 128

    fun decrypt(
        encoded: String,
        key: SecretKey,
        decodeBase64: (String) -> ByteArray,
    ): String {
        val parts = encoded.split(separator, limit = 2)
        if (parts.size != 2) {
            throw SecureStorageEntryUnreadableException()
        }
        val iv: ByteArray
        val ciphertext: ByteArray
        try {
            iv = decodeBase64(parts[0])
            ciphertext = decodeBase64(parts[1])
        } catch (error: IllegalArgumentException) {
            throw SecureStorageEntryUnreadableException(error)
        }
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(gcmTagBits, iv))
            return String(cipher.doFinal(ciphertext), StandardCharsets.UTF_8)
        } catch (error: InvalidAlgorithmParameterException) {
            throw SecureStorageEntryUnreadableException(error)
        } catch (error: AEADBadTagException) {
            throw SecureStorageEntryUnreadableException(error)
        } catch (error: BadPaddingException) {
            throw SecureStorageEntryUnreadableException(error)
        } catch (error: IllegalBlockSizeException) {
            throw SecureStorageEntryUnreadableException(error)
        }
    }
}
