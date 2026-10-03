package dev.eixam.connect.flutter.telemetry

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

internal object PhoneRadioBridge {
    private const val methodChannelName =
        "dev.eixam.connect_flutter/phone_radio/methods"

    private val reader = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "eixam-phone-radio").apply { isDaemon = true }
    }
    private var channel: MethodChannel? = null

    fun register(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        PhoneRadioMonitor.acquire(app)
        val methodChannel = MethodChannel(messenger, methodChannelName)
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "readPhoneRadio" -> reader.execute {
                    val payload = try {
                        PhoneRadioReader.read(app).toMap()
                    } catch (_: Throwable) {
                        PhoneRadioRaw(null, null, false).toMap()
                    }
                    try {
                        result.success(payload)
                    } catch (_: RuntimeException) {
                        // Engine already detached.
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
        PhoneRadioMonitor.release()
    }
}
