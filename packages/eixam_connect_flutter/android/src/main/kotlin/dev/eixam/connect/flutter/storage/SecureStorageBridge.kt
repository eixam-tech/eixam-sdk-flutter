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
import javax.crypto.spec.GCMParameterSpec

internal object SecureStorageBridge {
    private const val channelName = "dev.eixam.connect.flutter/secure_storage"
    private const val preferencesName = "eixam_secure_storage"
    private const val keyAlias = "eixam.secure.storage.v1"
    private const val separator = ":"
    private const val gcmTagBits = 128
    private var channel: MethodChannel? = null

    fun register(messenger: BinaryMessenger, context: Context) {
        val applicationContext = context.applicationContext
        channel = MethodChannel(messenger, channelName).also { methodChannel ->
            methodChannel.setMethodCallHandler { call, result ->
                try {
                    val preferences = applicationContext.getSharedPreferences(
                        preferencesName,
                        Context.MODE_PRIVATE,
                    )
                    when (call.method) {
                        "read" -> {
                            val key = call.argument<String>("key") ?: error("key is required")
                            val encrypted = preferences.getString(key, null)
                            result.success(encrypted?.let(::decrypt))
                        }
                        "write" -> {
                            val key = call.argument<String>("key") ?: error("key is required")
                            val value = call.argument<String>("value") ?: error("value is required")
                            if (!preferences.edit().putString(key, encrypt(value)).commit()) {
                                error("Secure storage write failed")
                            }
                            result.success(null)
                        }
                        "delete" -> {
                            val key = call.argument<String>("key") ?: error("key is required")
                            if (!preferences.edit().remove(key).commit()) {
                                error("Secure storage delete failed")
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
                            if (!editor.commit()) error("Secure storage delete-all failed")
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Throwable) {
                    result.error(
                        "secure_storage_unavailable",
                        error.message ?: "Secure storage operation failed",
                        null,
                    )
                }
            }
        }
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val ciphertext = cipher.doFinal(value.toByteArray(StandardCharsets.UTF_8))
        return Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + separator +
            Base64.encodeToString(ciphertext, Base64.NO_WRAP)
    }

    private fun decrypt(encoded: String): String {
        val parts = encoded.split(separator, limit = 2)
        require(parts.size == 2) { "Invalid secure storage payload" }
        val iv = Base64.decode(parts[0], Base64.NO_WRAP)
        val ciphertext = Base64.decode(parts[1], Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(gcmTagBits, iv))
        return String(cipher.doFinal(ciphertext), StandardCharsets.UTF_8)
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
