package dev.eixam.connect.flutter

import android.content.Context
import dev.eixam.connect.flutter.dfu.FirmwareDfuBridge
import dev.eixam.connect.flutter.protection.ProtectionRuntimeBridge
import dev.eixam.connect.flutter.telemetry.BackgroundTelemetryBridge
import dev.eixam.connect.flutter.storage.SecureStorageBridge
import io.flutter.embedding.engine.plugins.FlutterPlugin

class EixamConnectFlutterPlugin : FlutterPlugin {
    private var applicationContext: Context? = null
    private var protectionBridgeGeneration: Long? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        protectionBridgeGeneration = ProtectionRuntimeBridge.register(
            messenger = binding.binaryMessenger,
            context = binding.applicationContext,
        )
        BackgroundTelemetryBridge.register(
            messenger = binding.binaryMessenger,
            context = binding.applicationContext,
        )
        FirmwareDfuBridge.register(
            messenger = binding.binaryMessenger,
            context = binding.applicationContext,
        )
        SecureStorageBridge.register(
            messenger = binding.binaryMessenger,
            context = binding.applicationContext,
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext?.let {
            protectionBridgeGeneration?.let(ProtectionRuntimeBridge::unregister)
            BackgroundTelemetryBridge.unregister()
            FirmwareDfuBridge.unregister()
            SecureStorageBridge.unregister()
        }
        protectionBridgeGeneration = null
        applicationContext = null
    }
}
