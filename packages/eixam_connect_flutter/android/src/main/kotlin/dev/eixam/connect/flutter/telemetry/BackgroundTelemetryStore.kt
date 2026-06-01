package dev.eixam.connect.flutter.telemetry

import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject

internal class BackgroundTelemetryStore(context: Context) {
    private val preferences =
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
    private val flutterPreferences =
        context.getSharedPreferences(flutterPrefsName, Context.MODE_PRIVATE)

    fun saveStartRequest(arguments: Map<*, *>) {
        val session = arguments["session"] as? Map<*, *>
        preferences.edit()
            .putBoolean(keyEnabled, true)
            .putString(keyApiBaseUrl, arguments["apiBaseUrl"] as? String)
            .putString(keyAppId, session?.get("appId") as? String)
            .putString(keyExternalUserId, session?.get("externalUserId") as? String)
            .putString(keyUserHash, session?.get("userHash") as? String)
            .putString(keyCanonicalExternalUserId, session?.get("canonicalExternalUserId") as? String)
            .putDevicePayload(arguments)
            .putBoolean(keySosOpen, arguments["sosOpen"] as? Boolean ?: false)
            .putString(keyNotificationTitle, arguments["notificationTitle"] as? String)
            .putString(keyNotificationBody, arguments["notificationBody"] as? String)
            .putBoolean(keyActiveLocationRequest, false)
            .remove(keyLastError)
            .apply()
    }

    fun update(arguments: Map<*, *>) {
        preferences.edit()
            .putBoolean(keySosOpen, arguments["sosOpen"] as? Boolean ?: false)
            .putDevicePayload(arguments)
            .apply()
    }

    fun markServiceRunning(value: Boolean) {
        preferences.edit().putBoolean(keyServiceRunning, value).apply()
    }

    fun markStopped() {
        preferences.edit()
            .putBoolean(keyServiceRunning, false)
            .putBoolean(keyEnabled, false)
            .putBoolean(keyActiveLocationRequest, false)
            .remove(keyDeviceId)
            .remove(keyDeviceBattery)
            .remove(keyDeviceCoverage)
            .apply()
    }

    fun markPublished() {
        preferences.edit()
            .putLong(keyLastTelemetryAt, System.currentTimeMillis())
            .remove(keyLastError)
            .apply()
    }

    fun markError(error: String) {
        preferences.edit().putString(keyLastError, error).apply()
    }

    fun markLocationMode(mode: String) {
        preferences.edit().putString(keyLastLocationMode, mode).apply()
    }

    fun markPublishAttempt(reason: String, locationMode: String? = null) {
        preferences.edit()
            .putString(keyLastPublishReason, reason)
            .apply {
                if (locationMode != null) {
                    putString(keyLastLocationMode, locationMode)
                }
            }
            .apply()
    }

    fun markHttpStatusCode(statusCode: Int?) {
        preferences.edit()
            .apply {
                if (statusCode == null) {
                    remove(keyLastHttpStatusCode)
                } else {
                    putInt(keyLastHttpStatusCode, statusCode)
                }
            }
            .apply()
    }

    fun queueTelemetry(
        payload: JSONObject,
        reason: String,
        locationMode: String?,
        sosContext: Boolean,
    ): QueueResult {
        val now = System.currentTimeMillis()
        val sample = JSONObject(payload.toString())
        val signature = telemetrySignature(sample)
        val fresh = pendingTelemetryQueue(now)
        if (fresh.any { item -> item.signature == signature }) {
            preferences.edit()
                .putString(keyLastError, "TELEMETRY_NATIVE_DUPLICATE_SUPPRESSED")
                .putString(keyLastPublishReason, reason)
                .apply()
            return QueueResult(
                queued = false,
                duplicate = true,
                droppedOldest = false,
                signature = signature,
                queueSize = fresh.size,
            )
        }
        val updated = fresh.toMutableList()
        var droppedOldest = false
        while (updated.size >= maxQueuedTelemetrySamples) {
            val dropIndex = updated.indexOfFirst { !it.sosContext }
                .takeIf { it >= 0 }
                ?: 0
            updated.removeAt(dropIndex)
            droppedOldest = true
        }
        updated += QueuedTelemetry(
            signature = signature,
            payload = sample,
            enqueuedAt = now,
            retryCount = 0,
            reason = reason,
            locationMode = locationMode,
            sosContext = sosContext,
        )
        saveTelemetryQueue(updated)
        preferences.edit()
            .putString(keyLastError, "TELEMETRY_NATIVE_QUEUED")
            .putString(keyLastPublishReason, reason)
            .apply {
                if (locationMode != null) {
                    putString(keyLastLocationMode, locationMode)
                }
            }
            .apply()
        return QueueResult(
            queued = true,
            duplicate = false,
            droppedOldest = droppedOldest,
            signature = signature,
            queueSize = updated.size,
        )
    }

    fun peekQueuedTelemetry(limit: Int): List<Map<String, Any?>> {
        val fresh = pendingTelemetryQueue(System.currentTimeMillis())
        if (fresh.size != rawTelemetryQueueSize()) {
            saveTelemetryQueue(fresh)
        }
        return fresh.take(limit.coerceIn(1, maxQueuedTelemetrySamples)).map { item ->
            mapOf(
                "signature" to item.signature,
                "payload" to jsonObjectToMap(item.payload),
                "enqueuedAt" to item.enqueuedAt,
                "retryCount" to item.retryCount,
                "reason" to item.reason,
                "locationMode" to item.locationMode,
                "sosContext" to item.sosContext,
            )
        }
    }

    fun ackQueuedTelemetry(signature: String): Boolean {
        val normalized = signature.trim()
        if (normalized.isBlank()) {
            return false
        }
        val pending = pendingTelemetryQueue(System.currentTimeMillis())
        val remaining = pending.filterNot { it.signature == normalized }
        if (remaining.size == pending.size) {
            return false
        }
        saveTelemetryQueue(remaining)
        markPublished()
        return true
    }

    fun markQueuedTelemetryFlushFailed(signature: String, error: String) {
        val normalized = signature.trim()
        if (normalized.isBlank()) {
            markError(error)
            return
        }
        val pending = pendingTelemetryQueue(System.currentTimeMillis()).map { item ->
            if (item.signature == normalized) {
                item.copy(retryCount = item.retryCount + 1)
            } else {
                item
            }
        }
        saveTelemetryQueue(pending)
        markError(error)
    }

    fun markActiveLocationRequest(value: Boolean) {
        preferences.edit().putBoolean(keyActiveLocationRequest, value).apply()
    }

    fun snapshot(context: Context): Map<String, Any?> {
        return mapOf(
            "backgroundTelemetryEnabled" to preferences.getBoolean(keyEnabled, false),
            "androidForegroundServiceRunning" to preferences.getBoolean(keyServiceRunning, false),
            "backgroundPermissionStatus" to permissionStatus(context),
            "lastBackgroundTelemetryAt" to
                preferences.getLong(keyLastTelemetryAt, 0L).takeIf { it > 0L },
            "lastBackgroundTelemetryError" to preferences.getString(keyLastError, null),
            "lastBackgroundLocationMode" to preferences.getString(keyLastLocationMode, null),
            "lastBackgroundTelemetryHttpStatusCode" to
                preferences.getInt(keyLastHttpStatusCode, 0).takeIf { it > 0 },
            "lastBackgroundTelemetryReason" to
                preferences.getString(keyLastPublishReason, null),
            "activeLocationRequest" to preferences.getBoolean(keyActiveLocationRequest, false),
            "pendingNativeTelemetryCount" to pendingTelemetryQueue(System.currentTimeMillis()).size,
        )
    }

    fun isEnabled(): Boolean = preferences.getBoolean(keyEnabled, false)
    fun isSosOpen(): Boolean = preferences.getBoolean(keySosOpen, false)
    fun apiBaseUrl(): String? = preferences.getString(keyApiBaseUrl, null)
    fun appId(): String? = preferences.getString(keyAppId, null)
    fun externalUserId(): String? = preferences.getString(keyExternalUserId, null)
    fun canonicalExternalUserId(): String? =
        preferences.getString(keyCanonicalExternalUserId, null)
    fun userHash(): String? = preferences.getString(keyUserHash, null)
    fun deviceId(): String? =
        preferences.getString(keyDeviceId, null).takeUnless { isManualDisconnectRequested() }
    fun deviceBatteryJson(): String? =
        preferences.getString(keyDeviceBattery, null).takeUnless { isManualDisconnectRequested() }
    fun deviceCoverageJson(): String? =
        preferences.getString(keyDeviceCoverage, null).takeUnless { isManualDisconnectRequested() }
    fun notificationTitle(): String? = preferences.getString(keyNotificationTitle, null)
    fun notificationBody(): String? = preferences.getString(keyNotificationBody, null)

    private fun android.content.SharedPreferences.Editor.putDevicePayload(
        arguments: Map<*, *>,
    ): android.content.SharedPreferences.Editor {
        if (isManualDisconnectRequested()) {
            remove(keyDeviceId)
            remove(keyDeviceBattery)
            remove(keyDeviceCoverage)
            return this
        }
        putString(keyDeviceId, arguments["deviceId"] as? String)
        putString(keyDeviceBattery, compactJson(arguments["deviceBattery"]))
        putString(keyDeviceCoverage, compactJson(arguments["deviceCoverage"]))
        return this
    }

    private fun isManualDisconnectRequested(): Boolean =
        flutterPreferences.getBoolean(
            "$flutterKeyPrefix$manualDisconnectRequestedKey",
            false,
        )

    private fun compactJson(value: Any?): String? {
        val map = value as? Map<*, *> ?: return null
        return JSONObject(map).toString()
    }

    private fun pendingTelemetryQueue(now: Long): List<QueuedTelemetry> {
        val raw = preferences.getString(keyPendingTelemetryQueue, null)
            ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    val payload = item.optJSONObject("payload") ?: continue
                    val enqueuedAt = item.optLong("enqueuedAt", 0L)
                    if (enqueuedAt <= 0L || now - enqueuedAt > maxQueuedTelemetryAgeMs) {
                        continue
                    }
                    val signature = item.optString("signature").trim()
                        .takeIf { it.isNotBlank() }
                        ?: telemetrySignature(payload)
                    add(
                        QueuedTelemetry(
                            signature = signature,
                            payload = payload,
                            enqueuedAt = enqueuedAt,
                            retryCount = item.optInt("retryCount", 0),
                            reason = item.optString("reason").takeIf { it.isNotBlank() },
                            locationMode = item.optString("locationMode").takeIf { it.isNotBlank() },
                            sosContext = item.optBoolean("sosContext", false),
                        ),
                    )
                }
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun saveTelemetryQueue(pending: List<QueuedTelemetry>) {
        val editor = preferences.edit()
        if (pending.isEmpty()) {
            editor.remove(keyPendingTelemetryQueue)
        } else {
            val array = JSONArray()
            pending.forEach { item ->
                array.put(
                    JSONObject()
                        .put("signature", item.signature)
                        .put("payload", item.payload)
                        .put("enqueuedAt", item.enqueuedAt)
                        .put("retryCount", item.retryCount)
                        .put("reason", item.reason)
                        .put("locationMode", item.locationMode)
                        .put("sosContext", item.sosContext),
                )
            }
            editor.putString(keyPendingTelemetryQueue, array.toString())
        }
        editor.apply()
    }

    private fun rawTelemetryQueueSize(): Int {
        val raw = preferences.getString(keyPendingTelemetryQueue, null)
            ?: return 0
        return try {
            JSONArray(raw).length()
        } catch (_: Exception) {
            0
        }
    }

    private fun telemetrySignature(payload: JSONObject): String {
        payload.optString("eventId").trim().takeIf { it.isNotBlank() }?.let {
            return it
        }
        val timestamp = payload.optString("timestamp").trim().ifBlank { "none" }
        val deviceId = payload.optString("deviceId").trim().ifBlank { "none" }
        val latitude = payload.optDouble("latitude", Double.NaN)
        val longitude = payload.optDouble("longitude", Double.NaN)
        return listOf(timestamp, deviceId, latitude, longitude).joinToString(":")
    }

    private fun jsonObjectToMap(payload: JSONObject): Map<String, Any?> {
        val output = mutableMapOf<String, Any?>()
        val keys = payload.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            output[key] = jsonValueToDartValue(payload.get(key))
        }
        return output
    }

    private fun jsonValueToDartValue(value: Any?): Any? =
        when (value) {
            JSONObject.NULL -> null
            is JSONObject -> jsonObjectToMap(value)
            is JSONArray -> buildList {
                for (index in 0 until value.length()) {
                    add(jsonValueToDartValue(value.get(index)))
                }
            }
            else -> value
        }

    data class QueueResult(
        val queued: Boolean,
        val duplicate: Boolean,
        val droppedOldest: Boolean,
        val signature: String,
        val queueSize: Int,
    )

    private data class QueuedTelemetry(
        val signature: String,
        val payload: JSONObject,
        val enqueuedAt: Long,
        val retryCount: Int,
        val reason: String?,
        val locationMode: String?,
        val sosContext: Boolean,
    )

    private fun permissionStatus(context: Context): String {
        val fine = ContextCompat.checkSelfPermission(
            context,
            android.Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(
            context,
            android.Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        if (!fine && !coarse) {
            return "location_missing"
        }
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            val background = ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.ACCESS_BACKGROUND_LOCATION,
            ) == PackageManager.PERMISSION_GRANTED
            return if (background) "granted" else "foreground_only"
        }
        return "granted"
    }

    companion object {
        private const val prefsName = "eixam_background_telemetry"
        private const val flutterPrefsName = "FlutterSharedPreferences"
        private const val flutterKeyPrefix = "flutter."
        private const val keyEnabled = "enabled"
        private const val keyServiceRunning = "service_running"
        private const val keyApiBaseUrl = "api_base_url"
        private const val keyAppId = "app_id"
        private const val keyExternalUserId = "external_user_id"
        private const val keyCanonicalExternalUserId = "canonical_external_user_id"
        private const val keyUserHash = "user_hash"
        private const val keyDeviceId = "device_id"
        private const val keyDeviceBattery = "device_battery"
        private const val keyDeviceCoverage = "device_coverage"
        private const val keySosOpen = "sos_open"
        private const val keyNotificationTitle = "notification_title"
        private const val keyNotificationBody = "notification_body"
        private const val manualDisconnectRequestedKey =
            "eixam.ble.manual_disconnect_requested"
        private const val keyLastTelemetryAt = "last_telemetry_at"
        private const val keyLastError = "last_error"
        private const val keyLastLocationMode = "last_location_mode"
        private const val keyLastHttpStatusCode = "last_http_status_code"
        private const val keyLastPublishReason = "last_publish_reason"
        private const val keyActiveLocationRequest = "active_location_request"
        private const val keyPendingTelemetryQueue = "pending_telemetry_queue"
        private const val maxQueuedTelemetrySamples = 100
        private const val maxQueuedTelemetryAgeMs = 24 * 60 * 60 * 1000L
    }
}
