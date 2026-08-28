package dev.eixam.connect.flutter.storage

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

internal object SecureStorageBridge {
    private const val channelName = "dev.eixam.connect.flutter/secure_storage"
    private const val preferencesName = "eixam_secure_storage"
    private const val keyAlias = "eixam.secure.storage.v1"
    private var channel: MethodChannel? = null

    fun register(messenger: BinaryMessenger, context: Context) {
        val applicationContext = context.applicationContext
        channel = MethodChannel(messenger, channelName).also { methodChannel ->
            methodChannel.setMethodCallHandler { call, result ->
                val preferences = try {
                    applicationContext.getSharedPreferences(
                        preferencesName,
                        Context.MODE_PRIVATE,
                    )
                } catch (error: Throwable) {
                    respondWithError(result, error)
                    return@setMethodCallHandler
                }
                try {
                    when (call.method) {
                        "read" -> {
                            val key = call.argument<String>("key") ?: error("key is required")
                            val encrypted = preferences.getString(key, null)
                            result.success(encrypted?.let(::decrypt))
                        }
                        "write" -> {
                            val key = call.argument<String>("key") ?: error("key is required")
                            val value = call.argument<String>("value") ?: error("value is required")
                            val encrypted = encrypt(value)
                            try {
                                if (!preferences.edit().putString(key, encrypted).commit()) {
                                    throw SecureStorageWriteFailedException()
                                }
                            } catch (error: SecureStorageWriteFailedException) {
                                throw error
                            } catch (error: Throwable) {
                                throw SecureStorageWriteFailedException(error)
                            }
                            result.success(null)
                        }
                        "delete" -> {
                            val key = call.argument<String>("key") ?: error("key is required")
                            try {
                                if (!preferences.edit().remove(key).commit()) {
                                    throw SecureStorageDeleteFailedException()
                                }
                            } catch (error: SecureStorageDeleteFailedException) {
                                throw error
                            } catch (error: Throwable) {
                                throw SecureStorageDeleteFailedException(error)
                            }
                            result.success(null)
                        }
                        "deleteAll" -> {
                            val namespace = call.argument<String>("namespace")
                            val editor = preferences.edit()
                            if (namespace == null) {
                                editor.clear()
                            } else {
                                val generatedPrefix = "eixam.$namespace."
                                val rawPrefix = "$namespace."
                                preferences.all.keys
                                    .filter { it.startsWith(generatedPrefix) || it.startsWith(rawPrefix) }
                                    .forEach(editor::remove)
                            }
                            try {
                                if (!editor.commit()) {
                                    throw SecureStorageDeleteFailedException()
                                }
                            } catch (error: SecureStorageDeleteFailedException) {
                                throw error
                            } catch (error: Throwable) {
                                throw SecureStorageDeleteFailedException(error)
                            }
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Throwable) {
                    respondWithError(result, error)
                }
            }
        }
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun encrypt(value: String): String {
        val key = getOrCreateKey()
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key)
            val ciphertext = cipher.doFinal(value.toByteArray(StandardCharsets.UTF_8))
            return Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
                Base64.encodeToString(ciphertext, Base64.NO_WRAP)
        } catch (error: Throwable) {
            throw SecureStorageWriteFailedException(error)
        }
    }

    private fun decrypt(encoded: String): String {
        val key = getOrCreateKey()
        return SecureStoragePayloadCodec.decrypt(encoded, key) { value ->
            Base64.decode(value, Base64.NO_WRAP)
        }
    }

    private fun respondWithError(result: MethodChannel.Result, error: Throwable) {
        val code = SecureStorageFailureClassifier.codeFor(error)
        val message = when (code) {
            SecureStorageErrorCodes.entryUnreadable -> "Secure storage entry is unreadable."
            SecureStorageErrorCodes.writeFailed -> "Secure storage write failed."
            SecureStorageErrorCodes.deleteFailed -> "Secure storage delete failed."
            else -> "Secure storage is unavailable."
        }
        result.error(code, message, null)
    }

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(keyAlias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore",
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                keyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }
}
