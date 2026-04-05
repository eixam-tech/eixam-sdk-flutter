package dev.eixam.connect.flutter.protection

import android.bluetooth.BluetoothManager
import android.content.Context
import androidx.core.app.NotificationManagerCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal object ProtectionRuntimeBridge {
    private const val methodChannelName =
        "dev.eixam.connect_flutter/protection_runtime/methods"
    private const val eventChannelName =
        "dev.eixam.connect_flutter/protection_runtime/events"

    private var eventSink: EventChannel.EventSink? = null

    fun register(
        messenger: BinaryMessenger,
        context: Context,
    ) {
        MethodChannel(messenger, methodChannelName).setMethodCallHandler { call, result ->
            handleMethodCall(call, result, context.applicationContext)
        }
        EventChannel(messenger, eventChannelName).setStreamHandler(
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

    fun unregister() {
        eventSink = null
    }

    private fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context,
    ) {
        val store = ProtectionRuntimeStore(context)
        when (call.method) {
            "getPlatformSnapshot" -> {
                val bluetoothManager =
                    context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
                result.success(
                    store.snapshot() + mapOf(
                        "bluetoothEnabled" to (bluetoothManager.adapter?.isEnabled == true),
                        "notificationsGranted" to
                            NotificationManagerCompat.from(context).areNotificationsEnabled(),
                    ),
                )
            }

            "startProtectionRuntime" -> {
                val arguments = call.arguments as? Map<*, *>
                val activeDeviceId = arguments?.get("activeDeviceId") as? String
                val enableStoreAndForward =
                    arguments?.get("enableStoreAndForward") as? Boolean ?: true
                try {
                    store.markStartRequest(
                        activeDeviceId = activeDeviceId,
                        enableStoreAndForward = enableStoreAndForward,
                    )
                    ProtectionForegroundService.start(context)
                    recordPlatformEvent(
                        context = context,
                        type = "runtimeStarting",
                        reason = "enter_protection_mode",
                    )
                    result.success(
                        mapOf(
                            "success" to true,
                            "runtimeState" to "active",
                            "coverageLevel" to "partial",
                            "statusMessage" to
                                "Android foreground service is now SDK/plugin-owned. BLE ownership is assigned to the service while armed, and readiness advances to full once service BLE connection and subscriptions are confirmed.",
                        ),
                    )
                } catch (error: Exception) {
                    val reason = error.message ?: "Protection runtime start failed."
                    store.markRuntimeFailure(reason)
                    emitEvent("runtimeFailed", reason)
                    result.success(
                        mapOf(
                            "success" to false,
                            "runtimeState" to "failed",
                            "coverageLevel" to "none",
                            "failureReason" to reason,
                        ),
                    )
                }
            }

            "stopProtectionRuntime" -> {
                store.markStopped()
                ProtectionForegroundService.stop(context)
                result.success(null)
            }

            "flushProtectionQueues" -> result.success(store.flushQueues())
            else -> result.notImplemented()
        }
    }

    fun recordPlatformEvent(
        context: Context,
        type: String,
        reason: String? = null,
    ) {
        ProtectionRuntimeStore(context).recordEvent(type = type, reason = reason)
        emitEvent(type, reason)
    }

    fun recordBleEvent(
        context: Context,
        type: String,
        reason: String? = null,
    ) {
        ProtectionRuntimeStore(context).recordEvent(
            type = type,
            reason = reason,
            isBleEvent = true,
        )
        emitEvent(type, reason)
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
}
