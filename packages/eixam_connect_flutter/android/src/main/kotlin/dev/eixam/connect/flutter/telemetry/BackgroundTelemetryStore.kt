package dev.eixam.connect.flutter.telemetry

import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat

internal class BackgroundTelemetryStore(context: Context) {
    private val preferences =
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)

    fun saveStartRequest(arguments: Map<*, *>) {
        val session = arguments["session"] as? Map<*, *>
        preferences.edit()
            .putBoolean(keyEnabled, true)
            .putString(keyApiBaseUrl, arguments["apiBaseUrl"] as? String)
            .putString(keyAppId, session?.get("appId") as? String)
            .putString(keyExternalUserId, session?.get("externalUserId") as? String)
            .putString(keyUserHash, session?.get("userHash") as? String)
            .putString(keyCanonicalExternalUserId, session?.get("canonicalExternalUserId") as? String)
            .putString(keyDeviceId, arguments["deviceId"] as? String)
            .putString(keyDeviceBattery, compactJson(arguments["deviceBattery"]))
            .putString(keyDeviceCoverage, compactJson(arguments["deviceCoverage"]))
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
            .putString(keyDeviceId, arguments["deviceId"] as? String)
            .putString(keyDeviceBattery, compactJson(arguments["deviceBattery"]))
            .putString(keyDeviceCoverage, compactJson(arguments["deviceCoverage"]))
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
            "activeLocationRequest" to preferences.getBoolean(keyActiveLocationRequest, false),
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
    fun deviceId(): String? = preferences.getString(keyDeviceId, null)
    fun deviceBatteryJson(): String? = preferences.getString(keyDeviceBattery, null)
    fun deviceCoverageJson(): String? = preferences.getString(keyDeviceCoverage, null)
    fun notificationTitle(): String? = preferences.getString(keyNotificationTitle, null)
    fun notificationBody(): String? = preferences.getString(keyNotificationBody, null)

    private fun compactJson(value: Any?): String? {
        val map = value as? Map<*, *> ?: return null
        return org.json.JSONObject(map).toString()
    }

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
        private const val keyLastTelemetryAt = "last_telemetry_at"
        private const val keyLastError = "last_error"
        private const val keyLastLocationMode = "last_location_mode"
        private const val keyActiveLocationRequest = "active_location_request"
    }
}
