package dev.eixam.connect.flutter.telemetry

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal object BackgroundTelemetryBridge {
    private const val methodChannelName =
        "dev.eixam.connect_flutter/background_telemetry/methods"

    fun register(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, methodChannelName).setMethodCallHandler { call, result ->
            handle(call, result, context.applicationContext)
        }
    }

    fun unregister() {
        // The foreground service is intentionally independent once started.
    }

    private fun handle(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context,
    ) {
        val store = BackgroundTelemetryStore(context)
        when (call.method) {
            "startBackgroundTelemetry" -> {
                val arguments = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                store.saveStartRequest(arguments)
                try {
                    EixamTelemetryForegroundService.start(context)
                } catch (error: Exception) {
                    store.markError(error.message ?: error.javaClass.simpleName)
                    store.markStopped()
                    result.error(
                        "background_telemetry_start_failed",
                        error.message ?: error.javaClass.simpleName,
                        null,
                    )
                    return
                }
                result.success(null)
            }
            "updateBackgroundTelemetry" -> {
                val arguments = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                store.update(arguments)
                try {
                    EixamTelemetryForegroundService.update(context)
                } catch (error: Exception) {
                    store.markError(error.message ?: error.javaClass.simpleName)
                    result.error(
                        "background_telemetry_update_failed",
                        error.message ?: error.javaClass.simpleName,
                        null,
                    )
                    return
                }
                result.success(null)
            }
            "stopBackgroundTelemetry" -> {
                store.markStopped()
                try {
                    EixamTelemetryForegroundService.stop(context)
                } catch (error: Exception) {
                    store.markError(error.message ?: error.javaClass.simpleName)
                    result.error(
                        "background_telemetry_stop_failed",
                        error.message ?: error.javaClass.simpleName,
                        null,
                    )
                    return
                }
                result.success(null)
            }
            "getBackgroundTelemetryDiagnostics" -> {
                result.success(store.snapshot(context))
            }
            "peekQueuedBackgroundTelemetry" -> {
                val limit = ((call.arguments as? Map<*, *>)?.get("limit") as? Number)
                    ?.toInt()
                    ?: 25
                result.success(store.peekQueuedTelemetry(limit))
            }
            "ackQueuedBackgroundTelemetry" -> {
                val signature =
                    (call.arguments as? Map<*, *>)?.get("signature") as? String
                result.success(
                    if (signature == null) false
                    else store.ackQueuedTelemetry(signature),
                )
            }
            "markQueuedBackgroundTelemetryFlushFailed" -> {
                val arguments = call.arguments as? Map<*, *>
                val signature = arguments?.get("signature") as? String
                val error = arguments?.get("error") as? String ?: "mqtt_flush_failed"
                if (signature != null) {
                    store.markQueuedTelemetryFlushFailed(signature, error)
                } else {
                    store.markError(error)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
