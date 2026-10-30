package dev.eixam.connect.flutter

import android.content.Context
import dev.eixam.connect.flutter.permissions.LocationPermissionBridge
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import dev.eixam.connect.flutter.inspection.MeshtasticInspectionBridge
import dev.eixam.connect.flutter.dfu.FirmwareDfuBridge
import dev.eixam.connect.flutter.protection.ProtectionRuntimeBridge
import dev.eixam.connect.flutter.telemetry.BackgroundTelemetryBridge
import dev.eixam.connect.flutter.telemetry.PhoneRadioBridge
import dev.eixam.connect.flutter.storage.SecureStorageBridge
import dev.eixam.connect.flutter.storage.ActivityRecordingStorageBridge
import io.flutter.embedding.engine.plugins.FlutterPlugin

class EixamConnectFlutterPlugin : FlutterPlugin, ActivityAware {
    private var locationPermissionBridge: LocationPermissionBridge? = null
    private var inspectionBridge: MeshtasticInspectionBridge? = null
    private var applicationContext: Context? = null
    private var activityRecordingStorageBridge: ActivityRecordingStorageBridge? = null
    private var protectionBridgeGeneration: Long? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        locationPermissionBridge = LocationPermissionBridge(binding.binaryMessenger, binding.applicationContext)
        inspectionBridge = MeshtasticInspectionBridge(binding.binaryMessenger, binding.applicationContext)
        protectionBridgeGeneration = ProtectionRuntimeBridge.register(
            messenger = binding.binaryMessenger,
            context = binding.applicationContext,
        )
        BackgroundTelemetryBridge.register(
            messenger = binding.binaryMessenger,
            context = binding.applicationContext,
        )
        PhoneRadioBridge.register(
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
        activityRecordingStorageBridge = ActivityRecordingStorageBridge.register(
            binding.binaryMessenger, binding.applicationContext,
        )
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        locationPermissionBridge?.attach(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        locationPermissionBridge?.detach(forConfigurationChange = true)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        locationPermissionBridge?.attach(binding)
    }

    override fun onDetachedFromActivity() {
        locationPermissionBridge?.detach()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        locationPermissionBridge?.dispose()
        locationPermissionBridge = null
        applicationContext?.let {
            protectionBridgeGeneration?.let(ProtectionRuntimeBridge::unregister)
            BackgroundTelemetryBridge.unregister()
            PhoneRadioBridge.unregister()
            FirmwareDfuBridge.unregister()
            SecureStorageBridge.unregister()
            activityRecordingStorageBridge?.unregister()
            activityRecordingStorageBridge = null
        }
        inspectionBridge?.dispose()
        inspectionBridge = null
        protectionBridgeGeneration = null
        applicationContext = null
    }
}
