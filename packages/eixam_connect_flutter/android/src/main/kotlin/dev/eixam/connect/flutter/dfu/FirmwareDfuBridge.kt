package dev.eixam.connect.flutter.dfu

import android.Manifest
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import no.nordicsemi.android.dfu.DfuProgressListenerAdapter
import no.nordicsemi.android.dfu.DfuServiceController
import no.nordicsemi.android.dfu.DfuServiceInitiator
import no.nordicsemi.android.dfu.DfuServiceListenerHelper
import java.io.File

internal object FirmwareDfuBridge {
    private const val logTag = "OTA_DFU_ANDROID"
    private const val methodChannelName =
        "dev.eixam.connect_flutter/firmware_dfu/methods"
    private const val eventChannelName =
        "dev.eixam.connect_flutter/firmware_dfu/events"

    private val mainHandler = Handler(Looper.getMainLooper())
    private var applicationContext: Context? = null
    private var eventSink: EventChannel.EventSink? = null
    private var activeSession: ActiveDfuSession? = null

    fun register(
        messenger: BinaryMessenger,
        context: Context,
    ) {
        applicationContext = context.applicationContext
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
        activeSession?.controller?.abort()
        activeSession = null
        eventSink = null
        applicationContext = null
    }

    private fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context,
    ) {
        when (call.method) {
            "startDfu" -> startDfu(call, result, context)
            "cancelDfu" -> cancelDfu(call, result)
            else -> result.notImplemented()
        }
    }

    private fun startDfu(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context,
    ) {
        if (activeSession != null) {
            result.error("alreadyRunning", "A firmware DFU session is already running.", null)
            return
        }
        val arguments = call.arguments as? Map<*, *>
        val sessionId = (arguments?.get("sessionId") as? String)?.trim().orEmpty()
        val deviceId = (arguments?.get("deviceRemoteId") as? String)?.trim()
            ?: (arguments?.get("deviceId") as? String)?.trim()
            ?: ""
        val deviceName = (arguments?.get("deviceName") as? String)?.trim()
        val firmwareZipPath = (arguments?.get("firmwareZipPath") as? String)?.trim().orEmpty()
        val targetVersion = (arguments?.get("targetVersion") as? String)?.trim()
        val forceDfu = arguments?.get("forceDfu") as? Boolean ?: false
        val firmwareZip = File(firmwareZipPath)

        Log.i(
            logTag,
            "startDfu payload targetAddress=$deviceId filePath=$firmwareZipPath " +
                "fileSize=${if (firmwareZip.exists()) firmwareZip.length() else -1}",
        )

        val validationError = validateStart(
            context = context,
            sessionId = sessionId,
            deviceId = deviceId,
            firmwareZipPath = firmwareZipPath,
        )
        if (validationError != null) {
            result.error(validationError.code, validationError.message, null)
            return
        }

        val listener = object : DfuProgressListenerAdapter() {
            override fun onDeviceConnecting(deviceAddress: String) {
                Log.i(logTag, "onDeviceConnecting address=$deviceAddress")
                emit(
                    sessionId,
                    "connecting",
                    deviceAddress = deviceAddress,
                    message = "Connecting to DFU target.",
                )
            }

            override fun onDeviceConnected(deviceAddress: String) {
                Log.i(logTag, "onDeviceConnected address=$deviceAddress")
                emit(
                    sessionId,
                    "connected",
                    deviceAddress = deviceAddress,
                    message = "Connected to DFU target.",
                )
            }

            override fun onDfuProcessStarting(deviceAddress: String) {
                Log.i(logTag, "onDfuProcessStarting address=$deviceAddress")
                emit(
                    sessionId,
                    "dfuProcessStarting",
                    deviceAddress = deviceAddress,
                    message = "Starting DFU process.",
                )
            }

            override fun onDfuProcessStarted(deviceAddress: String) {
                Log.i(logTag, "onDfuProcessStarted address=$deviceAddress")
                emit(
                    sessionId,
                    "starting",
                    deviceAddress = deviceAddress,
                    message = "DFU process started.",
                )
            }

            override fun onEnablingDfuMode(deviceAddress: String) {
                Log.i(logTag, "onEnablingDfuMode address=$deviceAddress")
                emit(
                    sessionId,
                    "enablingDfuMode",
                    deviceAddress = deviceAddress,
                    message = "Switching device to DFU mode.",
                )
            }

            override fun onProgressChanged(
                deviceAddress: String,
                percent: Int,
                speed: Float,
                avgSpeed: Float,
                currentPart: Int,
                partsTotal: Int,
            ) {
                Log.i(
                    logTag,
                    "onProgressChanged address=$deviceAddress percent=$percent " +
                        "part=$currentPart/$partsTotal",
                )
                emit(
                    sessionId = sessionId,
                    state = "uploading",
                    deviceAddress = deviceAddress,
                    progressPct = percent.coerceIn(0, 100),
                    speedBytesPerSecond = speed.toDouble(),
                    part = currentPart,
                    totalParts = partsTotal,
                )
            }

            override fun onFirmwareValidating(deviceAddress: String) {
                Log.i(logTag, "onFirmwareValidating address=$deviceAddress")
                emit(
                    sessionId,
                    "firmwareValidating",
                    deviceAddress = deviceAddress,
                    message = "Validating firmware.",
                )
            }

            override fun onDeviceDisconnecting(deviceAddress: String) {
                Log.i(logTag, "onDeviceDisconnecting address=$deviceAddress")
                emit(
                    sessionId,
                    "deviceDisconnecting",
                    deviceAddress = deviceAddress,
                    message = "Device is rebooting after DFU.",
                )
            }

            override fun onDeviceDisconnected(deviceAddress: String) {
                Log.i(logTag, "onDeviceDisconnected address=$deviceAddress")
                emit(
                    sessionId,
                    "deviceDisconnected",
                    deviceAddress = deviceAddress,
                    message = "Device disconnected after DFU.",
                )
            }

            override fun onDfuCompleted(deviceAddress: String) {
                val completedAtMillis = System.currentTimeMillis()
                Log.i(
                    logTag,
                    "onDfuCompleted address=$deviceAddress completedAtMillis=$completedAtMillis",
                )
                emit(
                    sessionId,
                    "dfuCompleted",
                    deviceAddress = deviceAddress,
                    progressPct = 100,
                    completedAtMillis = completedAtMillis,
                )
                completeSuccess(sessionId)
            }

            override fun onDfuAborted(deviceAddress: String) {
                Log.w(logTag, "onDfuAborted address=$deviceAddress")
                emit(
                    sessionId = sessionId,
                    state = "dfuAborted",
                    deviceAddress = deviceAddress,
                    errorCode = "cancelled",
                    errorMessage = "Firmware DFU was cancelled.",
                )
                completeFailure(sessionId, "cancelled", "Firmware DFU was cancelled.")
            }

            override fun onError(
                deviceAddress: String,
                error: Int,
                errorType: Int,
                message: String?,
            ) {
                Log.e(
                    logTag,
                    "onError address=$deviceAddress error=$error type=$errorType " +
                        "message=${message ?: ""}",
                )
                val mapped = mapDfuError(error = error, errorType = errorType, message = message)
                emit(
                    sessionId = sessionId,
                    state = "dfuError",
                    deviceAddress = deviceAddress,
                    errorCode = mapped.code,
                    errorMessage = mapped.message,
                    requiresRecovery = mapped.requiresRecovery,
                )
                completeFailure(
                    sessionId,
                    mapped.code,
                    mapped.message,
                    requiresRecovery = mapped.requiresRecovery,
                )
            }
        }

        activeSession = ActiveDfuSession(
            sessionId = sessionId,
            listener = listener,
        )
        DfuServiceListenerHelper.registerProgressListener(context, listener)

        try {
            DfuServiceInitiator.createDfuNotificationChannel(context)
            val initiator = DfuServiceInitiator(deviceId)
                .setDeviceName(deviceName)
                .setForceDfu(forceDfu)
                .setKeepBond(true)
                .setForeground(true)
                .setNumberOfRetries(1)
                .setZip(firmwareZipPath)
            activeSession = activeSession?.copy(
                controller = initiator.start(context, EixamDfuService::class.java),
                targetVersion = targetVersion,
            )
            Log.i(logTag, "DFU service initiated sessionId=$sessionId targetAddress=$deviceId")
            emit(sessionId, "queued", message = "DFU transfer queued.")
            result.success(mapOf("success" to true, "started" to true))
        } catch (error: Exception) {
            DfuServiceListenerHelper.unregisterProgressListener(context, listener)
            activeSession = null
            Log.e(logTag, "DFU service initiation failed: ${error.message}", error)
            result.error("dfuFailed", error.message ?: "Failed to start firmware DFU.", null)
        }
    }

    private fun cancelDfu(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val sessionId = ((call.arguments as? Map<*, *>)?.get("sessionId") as? String)?.trim()
        val session = activeSession
        if (session == null || (sessionId != null && session.sessionId != sessionId)) {
            result.success(null)
            return
        }
        session.controller?.abort()
        emit(
            sessionId = session.sessionId,
            state = "dfuAborted",
            errorCode = "cancelled",
            errorMessage = "Firmware DFU cancellation requested.",
        )
        result.success(null)
    }

    private fun validateStart(
        context: Context,
        sessionId: String,
        deviceId: String,
        firmwareZipPath: String,
    ): DfuStartError? {
        if (sessionId.isEmpty()) {
            return DfuStartError("invalidSession", "DFU session id is missing.")
        }
        if (deviceId.isEmpty()) {
            return DfuStartError("deviceNotFound", "DFU target device id is missing.")
        }
        val file = File(firmwareZipPath)
        if (!file.exists() || !file.isFile) {
            return DfuStartError("fileMissing", "Firmware ZIP file is missing.")
        }
        if (!firmwareZipPath.lowercase().endsWith(".zip")) {
            return DfuStartError("invalidZip", "Firmware artifact must be a DFU ZIP file.")
        }
        val bluetoothManager =
            context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        if (bluetoothManager?.adapter?.isEnabled != true) {
            return DfuStartError("bluetoothDisabled", "Bluetooth is disabled.")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_CONNECT,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return DfuStartError("missingPermission", "BLUETOOTH_CONNECT is not granted.")
        }
        return null
    }

    private fun completeSuccess(sessionId: String) {
        val session = activeSession ?: return
        if (session.sessionId != sessionId) {
            return
        }
        cleanupSession(session)
    }

    private fun completeFailure(
        sessionId: String,
        code: String,
        message: String,
        requiresRecovery: Boolean = false,
    ) {
        val session = activeSession ?: return
        if (session.sessionId != sessionId) {
            return
        }
        cleanupSession(session)
    }

    private fun cleanupSession(session: ActiveDfuSession) {
        applicationContext?.let {
            DfuServiceListenerHelper.unregisterProgressListener(it, session.listener)
        }
        activeSession = null
    }

    private fun emit(
        sessionId: String,
        state: String,
        deviceAddress: String? = null,
        progressPct: Int? = null,
        speedBytesPerSecond: Double? = null,
        part: Int? = null,
        totalParts: Int? = null,
        message: String? = null,
        errorCode: String? = null,
        errorMessage: String? = null,
        requiresRecovery: Boolean = false,
        completedAtMillis: Long? = null,
    ) {
        val emittedAtMillis = System.currentTimeMillis()
        mainHandler.post {
            eventSink?.success(
                mapOf(
                    "sessionId" to sessionId,
                    "state" to state,
                    "deviceAddress" to deviceAddress,
                    "progressPct" to progressPct,
                    "speedBytesPerSecond" to speedBytesPerSecond,
                    "part" to part,
                    "totalParts" to totalParts,
                    "message" to message,
                    "errorCode" to errorCode,
                    "errorMessage" to errorMessage,
                    "requiresRecovery" to requiresRecovery,
                    "emittedAtMillis" to emittedAtMillis,
                    "completedAtMillis" to completedAtMillis,
                ),
            )
        }
    }

    private fun mapDfuError(
        error: Int,
        errorType: Int,
        message: String?,
    ): DfuFailure {
        val normalized = message?.lowercase().orEmpty()
        val code = when {
            normalized.contains("permission") -> "missingPermission"
            normalized.contains("bluetooth") && normalized.contains("disabled") ->
                "bluetoothDisabled"
            normalized.contains("file") || normalized.contains("zip") -> "invalidZip"
            normalized.contains("disconnect") -> "deviceDisconnected"
            normalized.contains("not found") -> "deviceNotFound"
            else -> "dfuFailed"
        }
        val requiresRecovery = code == "deviceDisconnected" || normalized.contains("bootloader")
        return DfuFailure(
            code = code,
            message = message ?: "DFU failed with error=$error type=$errorType.",
            requiresRecovery = requiresRecovery,
        )
    }

    private data class ActiveDfuSession(
        val sessionId: String,
        val listener: DfuProgressListenerAdapter,
        val controller: DfuServiceController? = null,
        val targetVersion: String? = null,
    )

    private data class DfuStartError(
        val code: String,
        val message: String,
    )

    private data class DfuFailure(
        val code: String,
        val message: String,
        val requiresRecovery: Boolean,
    )
}
