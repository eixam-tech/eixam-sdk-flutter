package dev.eixam.connect.flutter.protection

import android.content.Context

internal class ProtectionRuntimeStore(context: Context) {
    private val preferences =
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)

    fun snapshot(): Map<String, Any?> {
        val serviceRunning = preferences.getBoolean(keyServiceRunning, false)
        val runtimeActive = preferences.getBoolean(keyRuntimeActive, false)
        val bleOwner = preferences.getString(keyBleOwner, "flutter") ?: "flutter"
        val serviceBleConnected =
            preferences.getBoolean(keyServiceBleConnected, false)
        val serviceBleReady = preferences.getBoolean(keyServiceBleReady, false)
        val backgroundCapabilityState =
            preferences.getString(keyBackgroundCapabilityState, "configured")
                ?: "configured"
        val reconnectAttemptCount =
            preferences.getInt(keyReconnectAttemptCount, 0)
        val lastReconnectAttemptAt =
            preferences.getLong(keyLastReconnectAttemptAt, 0L).takeIf { it > 0L }

        return mapOf(
            "platformRuntimeConfigured" to true,
            "foregroundServiceConfigured" to true,
            "backgroundCapabilityReady" to true,
            "backgroundCapabilityState" to backgroundCapabilityState,
            "serviceRunning" to serviceRunning,
            "runtimeActive" to runtimeActive,
            "bleOwner" to bleOwner,
            "serviceBleConnected" to serviceBleConnected,
            "serviceBleReady" to serviceBleReady,
            "targetDeviceId" to preferences.getString(keyTargetDeviceId, null),
            "lastFailureReason" to preferences.getString(keyLastFailureReason, null),
            "lastPlatformEvent" to preferences.getString(keyLastPlatformEvent, null),
            "lastPlatformEventAt" to preferences.getLong(keyLastPlatformEventAt, 0L)
                .takeIf { it > 0L },
            "lastWakeAt" to preferences.getLong(keyLastWakeAt, 0L).takeIf { it > 0L },
            "lastWakeReason" to preferences.getString(keyLastWakeReason, null),
            "lastBleServiceEvent" to preferences.getString(keyLastBleServiceEvent, null),
            "lastBleServiceEventAt" to preferences.getLong(keyLastBleServiceEventAt, 0L)
                .takeIf { it > 0L },
            "reconnectAttemptCount" to reconnectAttemptCount,
            "lastReconnectAttemptAt" to lastReconnectAttemptAt,
            "pendingSosCount" to preferences.getInt(keyPendingSosCount, 0),
            "pendingTelemetryCount" to preferences.getInt(keyPendingTelemetryCount, 0),
            "runtimeState" to when {
                runtimeActive -> "active"
                serviceRunning -> "recovering"
                else -> "inactive"
            },
            "coverageLevel" to when {
                serviceBleReady -> "full"
                runtimeActive || serviceRunning -> "partial"
                else -> "none"
            },
            "degradationReason" to preferences.getString(
                keyDegradationReason,
                "Android Protection Mode runtime is armed in the SDK/plugin layer, but native BLE ownership is still recovering or not yet ready.",
            ),
        )
    }

    fun markStartRequest(
        activeDeviceId: String?,
        enableStoreAndForward: Boolean,
    ) {
        preferences.edit()
            .putString(keyTargetDeviceId, activeDeviceId)
            .putBoolean(keyServiceRunning, true)
            .putBoolean(keyRuntimeActive, true)
            .putString(keyBleOwner, "androidService")
            .putBoolean(keyStoreAndForwardEnabled, enableStoreAndForward)
            .putString(
                keyDegradationReason,
                "Android foreground service owns the Protection Mode runtime. Native BLE runtime readiness is still reported separately until service BLE subscriptions are active.",
            )
            .apply()
    }

    fun markStopped() {
        preferences.edit()
            .putBoolean(keyServiceRunning, false)
            .putBoolean(keyRuntimeActive, false)
            .putString(keyBleOwner, "flutter")
            .putBoolean(keyServiceBleConnected, false)
            .putBoolean(keyServiceBleReady, false)
            .apply()
    }

    fun markRuntimeFailure(reason: String) {
        preferences.edit()
            .putString(keyLastFailureReason, reason)
            .putBoolean(keyRuntimeActive, false)
            .apply()
    }

    fun recordEvent(
        type: String,
        reason: String?,
        isBleEvent: Boolean = false,
    ) {
        val now = System.currentTimeMillis()
        val editor = preferences.edit()
            .putString(keyLastPlatformEvent, type)
            .putLong(keyLastPlatformEventAt, now)
        if (reason != null) {
            editor.putString(keyLastWakeReason, reason)
        }
        if (type == "runtimeStarted" || type == "runtimeRestarted" || type == "runtimeRecovered") {
            editor.putLong(keyLastWakeAt, now)
        }
        if (isBleEvent) {
            editor
                .putString(keyLastBleServiceEvent, type)
                .putLong(keyLastBleServiceEventAt, now)
        }
        when (type) {
            "deviceConnected" -> editor.putBoolean(keyServiceBleConnected, true)
            "deviceDisconnected" -> editor
                .putBoolean(keyServiceBleConnected, false)
                .putBoolean(keyServiceBleReady, false)
            "subscriptionsActive" -> editor.putBoolean(keyServiceBleReady, true)
            "reconnectScheduled",
            "reconnectFailed",
            -> {
                val nextAttempt =
                    preferences.getInt(keyReconnectAttemptCount, 0) + 1
                editor
                    .putInt(keyReconnectAttemptCount, nextAttempt)
                    .putLong(keyLastReconnectAttemptAt, now)
            }
        }
        editor.apply()
    }

    fun flushQueues(): Map<String, Any> {
        val flushedSosCount = preferences.getInt(keyPendingSosCount, 0)
        val flushedTelemetryCount = preferences.getInt(keyPendingTelemetryCount, 0)
        preferences.edit()
            .putInt(keyPendingSosCount, 0)
            .putInt(keyPendingTelemetryCount, 0)
            .apply()
        return mapOf(
            "flushedSosCount" to flushedSosCount,
            "flushedTelemetryCount" to flushedTelemetryCount,
            "success" to true,
        )
    }

    companion object {
        private const val prefsName = "eixam_protection_runtime"
        private const val keyServiceRunning = "service_running"
        private const val keyRuntimeActive = "runtime_active"
        private const val keyBleOwner = "ble_owner"
        private const val keyServiceBleConnected = "service_ble_connected"
        private const val keyServiceBleReady = "service_ble_ready"
        private const val keyTargetDeviceId = "target_device_id"
        private const val keyStoreAndForwardEnabled = "store_and_forward_enabled"
        private const val keyPendingSosCount = "pending_sos_count"
        private const val keyPendingTelemetryCount = "pending_telemetry_count"
        private const val keyReconnectAttemptCount = "reconnect_attempt_count"
        private const val keyLastReconnectAttemptAt = "last_reconnect_attempt_at"
        private const val keyLastFailureReason = "last_failure_reason"
        private const val keyLastWakeReason = "last_wake_reason"
        private const val keyLastWakeAt = "last_wake_at"
        private const val keyLastPlatformEvent = "last_platform_event"
        private const val keyLastPlatformEventAt = "last_platform_event_at"
        private const val keyLastBleServiceEvent = "last_ble_service_event"
        private const val keyLastBleServiceEventAt = "last_ble_service_event_at"
        private const val keyBackgroundCapabilityState = "background_capability_state"
        private const val keyDegradationReason = "degradation_reason"
    }
}
