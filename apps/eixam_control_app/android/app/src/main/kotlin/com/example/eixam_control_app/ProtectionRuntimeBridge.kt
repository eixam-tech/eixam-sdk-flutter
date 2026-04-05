package com.example.eixam_control_app

import android.bluetooth.BluetoothManager
import android.content.Context
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

object ProtectionRuntimeBridge {
    private const val methodChannelName =
        "com.example.eixam_control_app/protection_runtime/methods"
    private const val eventChannelName =
        "com.example.eixam_control_app/protection_runtime/events"
    private const val prefsName = "eixam_protection_runtime"

    private const val keyServiceRunning = "service_running"
    private const val keyRuntimeActive = "runtime_active"
    private const val keyManualStopPending = "manual_stop_pending"
    private const val keyLastFailureReason = "last_failure_reason"
    private const val keyLastWakeReason = "last_wake_reason"
    private const val keyLastWakeAt = "last_wake_at"
    private const val keyLastPlatformEvent = "last_platform_event"
    private const val keyLastPlatformEventAt = "last_platform_event_at"

    private var eventSink: EventChannel.EventSink? = null

    fun register(flutterEngine: FlutterEngine, context: Context) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            methodChannelName,
        ).setMethodCallHandler { call, result ->
            handleMethodCall(call, result, context.applicationContext)
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            eventChannelName,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            },
        )
    }

    private fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context,
    ) {
        when (call.method) {
            "getPlatformSnapshot" -> result.success(buildSnapshot(context))
            "startProtectionRuntime" -> {
                try {
                    ProtectionForegroundService.start(context)
                    result.success(
                        mapOf(
                            "success" to true,
                            "runtimeState" to "active",
                            "coverageLevel" to "partial",
                            "statusMessage" to
                                "Android foreground service is active, but BLE/runtime ownership still depends on Flutter rehydration in this phase.",
                        ),
                    )
                } catch (error: Exception) {
                    markRuntimeFailed(context, error.message ?: "Protection runtime start failed.")
                    result.success(
                        mapOf(
                            "success" to false,
                            "runtimeState" to "failed",
                            "coverageLevel" to "none",
                            "failureReason" to
                                (error.message ?: "Protection runtime start failed."),
                        ),
                    )
                }
            }

            "stopProtectionRuntime" -> {
                ProtectionForegroundService.stop(context)
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    fun markRuntimeStarted(context: Context, reason: String?) {
        updateRuntimeState(
            context = context,
            eventType = "runtimeStarted",
            reason = reason ?: "service_started",
            serviceRunning = true,
            runtimeActive = true,
            clearFailure = true,
            markWake = true,
        )
    }

    fun markRuntimeRecovered(context: Context, reason: String?) {
        updateRuntimeState(
            context = context,
            eventType = "runtimeRecovered",
            reason = reason ?: "service_recovered",
            serviceRunning = true,
            runtimeActive = true,
            clearFailure = true,
            markWake = true,
        )
    }

    fun markRuntimeRestarted(context: Context, reason: String?) {
        updateRuntimeState(
            context = context,
            eventType = "runtimeRestarted",
            reason = reason ?: "service_restarted",
            serviceRunning = true,
            runtimeActive = true,
            clearFailure = true,
            markWake = true,
        )
    }

    fun markRuntimeStopped(context: Context, reason: String?) {
        updateRuntimeState(
            context = context,
            eventType = "runtimeStopped",
            reason = reason ?: "service_stopped",
            serviceRunning = false,
            runtimeActive = false,
        )
    }

    fun markRuntimeFailed(context: Context, reason: String) {
        prefs(context)
            .edit()
            .putString(keyLastFailureReason, reason)
            .putBoolean(keyRuntimeActive, false)
            .putString(keyLastPlatformEvent, "runtimeFailed")
            .putLong(keyLastPlatformEventAt, System.currentTimeMillis())
            .apply()
        emitEvent("runtimeFailed", reason)
    }

    fun markBluetoothState(context: Context, enabled: Boolean) {
        val eventType = if (enabled) "bluetoothTurnedOn" else "bluetoothTurnedOff"
        prefs(context)
            .edit()
            .putString(keyLastPlatformEvent, eventType)
            .putLong(keyLastPlatformEventAt, System.currentTimeMillis())
            .apply()
        emitEvent(eventType, if (enabled) "bluetooth_on" else "bluetooth_off")
    }

    fun consumeManualStopPending(context: Context): Boolean {
        val preferences = prefs(context)
        val pending = preferences.getBoolean(keyManualStopPending, false)
        if (pending) {
            preferences.edit().putBoolean(keyManualStopPending, false).apply()
        }
        return pending
    }

    fun markManualStopPending(context: Context) {
        prefs(context).edit().putBoolean(keyManualStopPending, true).apply()
    }

    fun isRuntimeMarkedActive(context: Context): Boolean {
        return prefs(context).getBoolean(keyRuntimeActive, false)
    }

    fun buildSnapshot(context: Context): Map<String, Any?> {
        val preferences = prefs(context)
        val bluetoothManager =
            context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val bluetoothEnabled = bluetoothManager.adapter?.isEnabled == true
        val serviceRunning = preferences.getBoolean(keyServiceRunning, false)
        val runtimeActive = preferences.getBoolean(keyRuntimeActive, false)

        return mapOf(
            "backgroundCapabilityReady" to true,
            "platformRuntimeConfigured" to true,
            "foregroundServiceConfigured" to true,
            "serviceRunning" to serviceRunning,
            "runtimeActive" to runtimeActive,
            "bluetoothEnabled" to bluetoothEnabled,
            "notificationsGranted" to NotificationManagerCompat.from(context).areNotificationsEnabled(),
            "lastFailureReason" to preferences.getString(keyLastFailureReason, null),
            "lastPlatformEvent" to preferences.getString(keyLastPlatformEvent, null),
            "lastPlatformEventAt" to preferences.getLong(keyLastPlatformEventAt, 0L).takeIf { it > 0L },
            "runtimeState" to when {
                runtimeActive -> "active"
                serviceRunning -> "recovering"
                else -> "inactive"
            },
            "coverageLevel" to if (runtimeActive || serviceRunning) "partial" else "none",
            "lastWakeAt" to preferences.getLong(keyLastWakeAt, 0L).takeIf { it > 0L },
            "lastWakeReason" to preferences.getString(keyLastWakeReason, null),
        )
    }

    private fun updateRuntimeState(
        context: Context,
        eventType: String,
        reason: String,
        serviceRunning: Boolean,
        runtimeActive: Boolean,
        clearFailure: Boolean = false,
        markWake: Boolean = false,
    ) {
        val now = System.currentTimeMillis()
        val editor = prefs(context)
            .edit()
            .putBoolean(keyServiceRunning, serviceRunning)
            .putBoolean(keyRuntimeActive, runtimeActive)
            .putString(keyLastPlatformEvent, eventType)
            .putLong(keyLastPlatformEventAt, now)

        if (markWake) {
            editor
                .putLong(keyLastWakeAt, now)
                .putString(keyLastWakeReason, reason)
        }
        if (clearFailure) {
            editor.remove(keyLastFailureReason)
        }
        editor.apply()
        emitEvent(eventType, reason)
    }

    private fun emitEvent(type: String, reason: String?) {
        eventSink?.success(
            mapOf(
                "type" to type,
                "timestamp" to System.currentTimeMillis(),
                "reason" to reason,
            ),
        )
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
}
