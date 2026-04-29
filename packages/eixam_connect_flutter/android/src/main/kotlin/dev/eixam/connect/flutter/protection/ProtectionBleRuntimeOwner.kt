package dev.eixam.connect.flutter.protection

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.BluetoothManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.Locale
import java.util.UUID

internal class ProtectionBleRuntimeOwner(
    private val context: Context,
    private val runtimeStore: ProtectionRuntimeStore,
) {
    private val bluetoothManager =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var bluetoothGatt: BluetoothGatt? = null
    private var targetDeviceId: String? = null
    private var reconnectBackoffMs: Long = defaultReconnectBackoffMs
    private var reconnectRunnable: Runnable? = null
    private var reconnectAttemptCount = 0
    private var isStopping = false
    private var runtimeActive = false
    private var telNotifyCharacteristic: BluetoothGattCharacteristic? = null
    private var sosNotifyCharacteristic: BluetoothGattCharacteristic? = null
    private var inetWriteCharacteristic: BluetoothGattCharacteristic? = null
    private var cmdWriteCharacteristic: BluetoothGattCharacteristic? = null
    private var subscriptionStep = SubscriptionStep.idle
    private var pendingSosLifecycleState = ProtectionSosLifecycleState.idle
    private var sosActivationRunnable: Runnable? = null
    private var backendRetryRunnable: Runnable? = null
    private var connectionInFlight = false
    private var pendingCommandResult: PendingCommandResult? = null
    private var connectedBleNodeId: Int? = null
    private val backendHandoff =
        ProtectionSosBackendHandoff(
            context = context,
            runtimeStore = runtimeStore,
            scheduleRetry = ::scheduleBackendFlush,
        )

    fun start(
        deviceId: String,
        reconnectBackoffMs: Long,
        restored: Boolean,
    ) {
        if (runtimeActive && targetDeviceId == deviceId) {
            this.reconnectBackoffMs = reconnectBackoffMs.coerceAtLeast(1000L)
            ensureConnectedOrReconnect(
                reason = if (restored) "restored_runtime_reconnect" else "runtime_reconnect",
            )
            return
        }
        targetDeviceId = deviceId
        connectedBleNodeId = null
        this.reconnectBackoffMs = reconnectBackoffMs.coerceAtLeast(1000L)
        isStopping = false
        runtimeActive = true
        if (restored) {
            ProtectionRuntimeBridge.recordPlatformEvent(
                context = context,
                type = "restorationRehydrated",
                reason = "runtime_owner_restored",
            )
        }
        backendHandoff.rehydrateBackendState(
            reason = if (restored) "restored_runtime_state" else "fresh_runtime_state",
        )
        backendHandoff.flushPendingActions(
            reason = if (restored) "restored_runtime_flush" else "runtime_start_flush",
        )
        connect(reason = if (restored) "restored_runtime_connect" else "runtime_connect")
    }

    fun stop(reason: String) {
        isStopping = true
        runtimeActive = false
        reconnectRunnable?.let(mainHandler::removeCallbacks)
        backendRetryRunnable?.let(mainHandler::removeCallbacks)
        sosActivationRunnable?.let(mainHandler::removeCallbacks)
        reconnectRunnable = null
        backendRetryRunnable = null
        sosActivationRunnable = null
        subscriptionStep = SubscriptionStep.idle
        pendingSosLifecycleState = ProtectionSosLifecycleState.idle
        connectedBleNodeId = null
        clearCharacteristicRefs()
        bluetoothGatt?.close()
        bluetoothGatt = null
        runtimeStore.markServiceBleDisconnected()
        ProtectionRuntimeBridge.recordBleEvent(
            context = context,
            type = "deviceDisconnected",
            reason = reason,
        )
    }

    fun isRunning(): Boolean = runtimeActive

    fun isRunningFor(deviceId: String): Boolean =
        runtimeActive && targetDeviceId == deviceId

    fun flushPendingBackendActions(reason: String): Map<String, Any> =
        backendHandoff.flushPendingActionsSync(reason)

    fun ensureConnectedOrReconnect(reason: String) {
        if (!runtimeActive || isStopping || targetDeviceId.isNullOrBlank()) {
            return
        }
        if (runtimeStore.snapshot()["serviceBleReady"] == true) {
            ProtectionRuntimeBridge.recordPlatformEvent(
                context = context,
                type = "runtimeRecovered",
                reason = reason,
            )
            return
        }
        if (connectionInFlight || reconnectRunnable != null) {
            runtimeStore.recordReadinessFailureReason(
                "Android foreground service is reconnecting to the protected BLE device.",
            )
            ProtectionRuntimeBridge.recordPlatformEvent(
                context = context,
                type = "runtimeRecovered",
                reason = "${reason}_reconnect_in_progress",
            )
            return
        }
        connect(reason = reason)
    }

    @SuppressLint("MissingPermission")
    fun sendCommand(
        label: String,
        payload: ByteArray,
        forceCmdCharacteristic: Boolean,
    ): Map<String, Any?> {
        val route = "androidService"
        runtimeStore.recordCommandRoute(route)
        if (!runtimeActive) {
            val error = "Protection Mode native BLE owner is not active."
            runtimeStore.recordCommandError(error)
            return commandResult(
                success = false,
                route = route,
                result = null,
                error = error,
            )
        }
        val gatt = bluetoothGatt
        val serviceBleConnected =
            runtimeStore.snapshot()["serviceBleConnected"] as? Boolean ?: false
        if (gatt == null || !serviceBleConnected) {
            val error =
                "Protection Mode native BLE owner is not connected to the protected device."
            runtimeStore.recordCommandError(error)
            ensureConnectedOrReconnect("native_command_$label")
            return commandResult(
                success = false,
                route = route,
                result = null,
                error = error,
            )
        }

        val characteristic =
            if (forceCmdCharacteristic || payload.size > inetMaxPayloadLength) {
                cmdWriteCharacteristic ?: inetWriteCharacteristic
            } else {
                inetWriteCharacteristic ?: cmdWriteCharacteristic
            }

        if (characteristic == null) {
            val error =
                "Protection Mode native BLE owner does not have a writable command characteristic ready."
            runtimeStore.recordCommandError(error)
            return commandResult(
                success = false,
                route = route,
                result = null,
                error = error,
            )
        }

        pendingCommandResult = PendingCommandResult(label = label)
        val writeAccepted =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(
                    characteristic,
                    payload,
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                ) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                run {
                    characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                    characteristic.value = payload
                    gatt.writeCharacteristic(characteristic)
                }
            }
        if (!writeAccepted) {
            pendingCommandResult = null
            val error = "Android native BLE owner rejected the $label write request."
            runtimeStore.recordCommandError(error)
            return commandResult(
                success = false,
                route = route,
                result = null,
                error = error,
            )
        }
        val result = "$label native write accepted via androidService."
        runtimeStore.recordCommandResult(result)
        return commandResult(
            success = true,
            route = route,
            result = result,
            error = null,
        )
    }

    fun dispose() {
        backendHandoff.dispose()
    }

    @SuppressLint("MissingPermission")
    private fun connect(reason: String) {
        val adapter = bluetoothManager.adapter
        val deviceId = targetDeviceId
        if (adapter == null || !adapter.isEnabled || deviceId.isNullOrBlank()) {
            runtimeStore.markRuntimeFailure("Bluetooth adapter is unavailable for Protection Mode.")
            ProtectionRuntimeBridge.recordPlatformEvent(
                context = context,
                type = "runtimeError",
                reason = "bluetooth_unavailable",
            )
            return
        }

        reconnectRunnable?.let(mainHandler::removeCallbacks)
        reconnectRunnable = null
        connectionInFlight = true
        connectedBleNodeId = null
        clearCharacteristicRefs()
        subscriptionStep = SubscriptionStep.idle
        runtimeStore.recordReadinessFailureReason(
            "Android foreground service is connecting to the protected BLE device.",
        )
        ProtectionRuntimeBridge.recordBleEvent(
            context = context,
            type = "deviceConnecting",
            reason = reason,
        )

        try {
            val device = adapter.getRemoteDevice(deviceId)
            bluetoothGatt?.close()
            bluetoothGatt =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    device.connectGatt(
                        context,
                        false,
                        gattCallback,
                        BluetoothDevice.TRANSPORT_LE,
                    )
                } else {
                    device.connectGatt(context, false, gattCallback)
                }
            if (bluetoothGatt == null) {
                connectionInFlight = false
                runtimeStore.markRuntimeFailure("Protection Mode could not open a Bluetooth GATT session.")
                ProtectionRuntimeBridge.recordBleEvent(
                    context = context,
                    type = "reconnectFailed",
                    reason = "connect_gatt_returned_null",
                )
                scheduleReconnect("connect_gatt_returned_null")
            }
        } catch (error: IllegalArgumentException) {
            connectionInFlight = false
            runtimeStore.markRuntimeFailure("Invalid protected device identifier: $deviceId")
            ProtectionRuntimeBridge.recordPlatformEvent(
                context = context,
                type = "runtimeError",
                reason = "invalid_device_id",
            )
        }
    }

    @SuppressLint("MissingPermission")
    private fun scheduleReconnect(reason: String) {
        if (isStopping || !runtimeActive) {
            return
        }
        reconnectAttemptCount += 1
        runtimeStore.markReconnectAttempt(reconnectAttemptCount)
        ProtectionRuntimeBridge.recordBleEvent(
            context = context,
            type = "reconnectScheduled",
            reason = reason,
        )
        reconnectRunnable = Runnable {
            if (!isStopping && runtimeActive) {
                connect(reason = "scheduled_reconnect_$reconnectAttemptCount")
            }
        }.also {
            mainHandler.postDelayed(it, reconnectBackoffMs)
        }
    }

    private fun scheduleBackendFlush(reason: String) {
        if (isStopping || !runtimeActive) {
            return
        }
        backendRetryRunnable?.let(mainHandler::removeCallbacks)
        backendRetryRunnable = Runnable {
            if (!isStopping && runtimeActive) {
                backendHandoff.flushPendingActions(reason)
            }
        }.also {
            mainHandler.postDelayed(it, reconnectBackoffMs)
        }
    }

    @SuppressLint("MissingPermission")
    private fun discoverServices(gatt: BluetoothGatt) {
        val discovered = gatt.discoverServices()
        if (!discovered) {
            runtimeStore.markRuntimeFailure("Protection Mode service discovery failed to start.")
            ProtectionRuntimeBridge.recordPlatformEvent(
                context = context,
                type = "runtimeError",
                reason = "discover_services_failed",
            )
            scheduleReconnect("discover_services_failed")
        }
    }

    @SuppressLint("MissingPermission")
    private fun configureSubscriptions(gatt: BluetoothGatt) {
        val discoveredServicesSummary = gatt.services.joinToString(separator = " | ") { service ->
            val characteristics = service.characteristics.joinToString(separator = ",") {
                it.uuid.toString().lowercase(Locale.US)
            }
            "${service.uuid.toString().lowercase(Locale.US)}[$characteristics]"
        }
        runtimeStore.recordDiscoveredServicesSummary(discoveredServicesSummary)
        val service = gatt.getService(serviceUuid)
        if (service == null) {
            val failureReason =
                "Expected BLE service ${serviceUuid.toString().lowercase(Locale.US)} was not found. Discovered services: ${if (discoveredServicesSummary.isBlank()) "none" else discoveredServicesSummary}"
            runtimeStore.markRuntimeFailure(failureReason)
            ProtectionRuntimeBridge.recordPlatformEvent(
                context = context,
                type = "runtimeError",
                reason = failureReason,
            )
            scheduleReconnect("eixam_service_missing")
            return
        }

        telNotifyCharacteristic = service.getCharacteristic(telNotifyUuid)
        sosNotifyCharacteristic = service.getCharacteristic(sosNotifyUuid)
        inetWriteCharacteristic = service.getCharacteristic(inetWriteUuid)
        cmdWriteCharacteristic = service.getCharacteristic(cmdWriteUuid)

        if (telNotifyCharacteristic == null || sosNotifyCharacteristic == null || inetWriteCharacteristic == null) {
            val missingCharacteristics = buildList<String> {
                if (telNotifyCharacteristic == null) add(telNotifyUuid.toString().lowercase(Locale.US))
                if (sosNotifyCharacteristic == null) add(sosNotifyUuid.toString().lowercase(Locale.US))
                if (inetWriteCharacteristic == null) add(inetWriteUuid.toString().lowercase(Locale.US))
            }
            val discoveredCharacteristics = service.characteristics.joinToString(separator = ",") {
                it.uuid.toString().lowercase(Locale.US)
            }
            val failureReason =
                "Required EIXAM protection characteristics are missing. Expected ${missingCharacteristics.joinToString()} but discovered $discoveredCharacteristics."
            runtimeStore.markRuntimeFailure(failureReason)
            ProtectionRuntimeBridge.recordPlatformEvent(
                context = context,
                type = "runtimeError",
                reason = failureReason,
            )
            scheduleReconnect("required_characteristics_missing")
            return
        }

        runtimeStore.recordReadinessFailureReason(
            "Expected BLE service and required characteristics were discovered. Enabling TEL/SOS notifications.",
        )
        ProtectionRuntimeBridge.recordBleEvent(
            context = context,
            type = "servicesDiscovered",
            reason = "expected_service_and_characteristics_found",
        )
        subscriptionStep = SubscriptionStep.tel
        enableCharacteristicNotifications(gatt, telNotifyCharacteristic!!)
    }

    @SuppressLint("MissingPermission")
    private fun enableCharacteristicNotifications(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
    ) {
        val notificationEnabled = gatt.setCharacteristicNotification(characteristic, true)
        if (!notificationEnabled) {
            runtimeStore.markRuntimeFailure("Could not enable notifications for ${characteristic.uuid}.")
            ProtectionRuntimeBridge.recordPlatformEvent(
                context = context,
                type = "runtimeError",
                reason = "set_notify_failed",
            )
            scheduleReconnect("set_notify_failed")
            return
        }

        val descriptor = characteristic.getDescriptor(clientCharacteristicConfigUuid)
        if (descriptor == null) {
            runtimeStore.markRuntimeFailure("Missing CCCD for ${characteristic.uuid}.")
            ProtectionRuntimeBridge.recordPlatformEvent(
                context = context,
                type = "runtimeError",
                reason = "cccd_missing",
            )
            scheduleReconnect("cccd_missing")
            return
        }

        descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        val writeStarted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) ==
                BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            gatt.writeDescriptor(descriptor)
        }
        if (!writeStarted) {
            runtimeStore.markRuntimeFailure("Could not write CCCD for ${characteristic.uuid}.")
            ProtectionRuntimeBridge.recordPlatformEvent(
                context = context,
                type = "runtimeError",
                reason = "cccd_write_failed",
            )
            scheduleReconnect("cccd_write_failed")
        }
    }

    private fun clearCharacteristicRefs() {
        telNotifyCharacteristic = null
        sosNotifyCharacteristic = null
        inetWriteCharacteristic = null
        cmdWriteCharacteristic = null
    }

    private fun handleIncomingPacket(
        characteristic: BluetoothGattCharacteristic,
        rawBytes: ByteArray,
    ) {
        val payload = rawBytes.map { byte -> byte.toInt() and 0xFF }
        val sourceLabel = when (characteristic.uuid) {
            sosNotifyUuid -> "sos_notify"
            telNotifyUuid -> when (payload.firstOrNull()) {
                0xD0 -> "tel_fragment"
                0xD2 -> "d2_relay"
                else -> "tel_notify"
            }
            else -> "unknown"
        }
        logSosTrace(
            "native_raw_notify source=$sourceLabel payloadLen=${payload.size} " +
                "payloadHex=${payloadHex(payload)} connectedBleNodeId=${connectedBleNodeId ?: "none"}",
        )
        runtimeStore.recordPacket(payload)
        ProtectionRuntimeBridge.recordBleEvent(
            context = context,
            type = "packetReceived",
            reason = "${characteristic.uuid}:${payload.size}",
        )

        if (characteristic.uuid == telNotifyUuid) {
            ProtectionBleSosIdentityClassifier.tryParseDeviceRuntimeNodeId(payload)?.let { nodeId ->
                connectedBleNodeId = nodeId
                ProtectionRuntimeBridge.recordBleEvent(
                    context = context,
                    type = "deviceRuntimeStatusReceived",
                    reason = "nodeId=$nodeId",
                )
            }
            if (payload.size == 27 && payload.firstOrNull() == 0xD2) {
                val peerPayload = payload.subList(1, 13).toList()
                val selfPayload = payload.subList(15, 27).toList()
                connectedBleNodeId = connectedBleNodeId ?: readU32OrNull(selfPayload, 0)
                when (
                    val classification = ProtectionBleSosIdentityClassifier.classify(
                        payload = peerPayload,
                        connectedNodeId = connectedBleNodeId,
                        source = ProtectionBleSosRelaySource.d2,
                    )
                ) {
                    is ProtectionBleSosIdentityClassification.RemoteSos -> {
                        recordRemoteRelaySosPayload(classification)
                        return
                    }

                    is ProtectionBleSosIdentityClassification.UnknownOriginSos -> {
                        recordUnknownOriginSosPayload(classification)
                        return
                    }

                    else -> Unit
                }
            }
            when (
                val classification = ProtectionBleSosIdentityClassifier.classify(
                    payload = payload,
                    connectedNodeId = connectedBleNodeId,
                    source = ProtectionBleSosRelaySource.tel,
                )
            ) {
                is ProtectionBleSosIdentityClassification.RemoteSos -> {
                    recordRemoteRelaySosPayload(classification)
                    return
                }

                is ProtectionBleSosIdentityClassification.UnknownOriginSos -> {
                    recordUnknownOriginSosPayload(classification)
                    return
                }

                ProtectionBleSosIdentityClassification.OwnSos -> {
                    logSosPacketDecodeForTrace(
                        payload = payload,
                        source = ProtectionBleSosRelaySource.tel,
                        classificationLabel = "ownDeviceSos",
                    )
                    logSosTrace(
                        "native_lifecycle_gate classification=ownDeviceSos " +
                            "action=enter_local_lifecycle observeSosLifecycle_called=true",
                    )
                    ProtectionRuntimeBridge.recordBleEvent(
                        context = context,
                        type = "telDerivedSosReceived",
                        reason = payloadHex(payload),
                    )
                    observeSosLifecycle(payload)
                    return
                }

                else -> Unit
            }
            logSosPacketDecodeForTrace(
                payload = payload,
                source = ProtectionBleSosRelaySource.tel,
                classificationLabel = "notSos",
            )
        }

        if (characteristic.uuid == sosNotifyUuid) {
            val classification = ProtectionBleSosIdentityClassifier.classify(
                payload = payload,
                connectedNodeId = connectedBleNodeId,
                source = ProtectionBleSosRelaySource.sos,
            )
            when (classification) {
                is ProtectionBleSosIdentityClassification.RemoteSos -> {
                    recordRemoteRelaySosPayload(classification)
                    return
                }

                is ProtectionBleSosIdentityClassification.UnknownOriginSos -> {
                    recordUnknownOriginSosPayload(classification)
                    return
                }

                is ProtectionBleSosIdentityClassification.RemoteEvent -> {
                    recordRemoteRelayEventPayload(classification)
                    return
                }

                else -> Unit
            }
            logSosPacketDecodeForTrace(
                payload = payload,
                source = ProtectionBleSosRelaySource.sos,
                classificationLabel =
                    if (classification == ProtectionBleSosIdentityClassification.OwnSos ||
                        classification == ProtectionBleSosIdentityClassification.OwnEvent
                    ) {
                        "ownDeviceSos"
                    } else {
                        "notSos"
                    },
            )
            ProtectionRuntimeBridge.recordBleEvent(
                context = context,
                type = "sosEventReceived",
                reason = payloadHex(payload),
            )
            logSosTrace(
                "native_lifecycle_gate classification=ownDeviceSos " +
                    "action=enter_local_lifecycle observeSosLifecycle_called=true",
            )
            observeSosLifecycle(payload)
        }
    }

    private fun recordUnknownOriginSosPayload(
        classification: ProtectionBleSosIdentityClassification.UnknownOriginSos,
    ) {
        logSosTrace(
            "native_sos_decode originatorNodeId=${classification.originatorNodeId} " +
                "connectedBleNodeId=${connectedBleNodeId ?: "none"} sosType=${classification.sosType} " +
                "classification=unknownOriginSos hasLocation=${classification.position != null} " +
                "lat=${classification.position?.latitude ?: "none"} lon=${classification.position?.longitude ?: "none"} " +
                "alt=${classification.position?.altitude ?: "none"} source=${classification.source.name} " +
                "payloadLen=${classification.rawPayload.size} payloadHex=${payloadHex(classification.rawPayload)}",
        )
        ProtectionRuntimeBridge.recordBleEvent(
            context = context,
            type = "unknownOriginSosReceived",
            reason =
                "originatorNodeId=${classification.originatorNodeId};source=${classification.source.name}",
        )
        logSosTrace(
            "native_lifecycle_gate classification=unknownOriginSos " +
                "action=skip_unknown_identity observeSosLifecycle_called=false",
        )
        logSosTrace(
            "platform_event type=sosEventReceived originatorNodeId=${classification.originatorNodeId} " +
                "relayNodeId=none hasLocation=${classification.position != null} " +
                "lat=${classification.position?.latitude ?: "none"} lon=${classification.position?.longitude ?: "none"} " +
                "alt=${classification.position?.altitude ?: "none"} payloadHex=${payloadHex(classification.rawPayload)}",
        )
        ProtectionRuntimeBridge.recordPlatformEvent(
            context = context,
            type = "sosEventReceived",
            reason =
                "unknown:${classification.source.name}:${payloadHex(classification.rawPayload)}",
        )
    }

    private fun recordRemoteRelaySosPayload(
        classification: ProtectionBleSosIdentityClassification.RemoteSos,
    ) {
        logSosTrace(
            "native_sos_decode originatorNodeId=${classification.originatorNodeId} " +
                "connectedBleNodeId=${connectedBleNodeId ?: "none"} sosType=${classification.sosType} " +
                "classification=remoteRelaySos hasLocation=${classification.position != null} " +
                "lat=${classification.position?.latitude ?: "none"} lon=${classification.position?.longitude ?: "none"} " +
                "alt=${classification.position?.altitude ?: "none"} source=${classification.source.name} " +
                "payloadLen=${classification.rawPayload.size} payloadHex=${payloadHex(classification.rawPayload)}",
        )
        logSosTrace(
            "native_lifecycle_gate classification=remoteRelaySos " +
                "action=emit_remote_relay observeSosLifecycle_called=false",
        )
        ProtectionRuntimeBridge.recordBleEvent(
            context = context,
            type = "remoteRelaySosReceived",
            reason =
                "originatorNodeId=${classification.originatorNodeId};relayNodeId=${classification.relayNodeId};source=${classification.source.name}",
        )
        logSosTrace(
            "platform_event type=sosEventReceived originatorNodeId=${classification.originatorNodeId} " +
                "relayNodeId=${classification.relayNodeId} hasLocation=${classification.position != null} " +
                "lat=${classification.position?.latitude ?: "none"} lon=${classification.position?.longitude ?: "none"} " +
                "alt=${classification.position?.altitude ?: "none"} payloadHex=${payloadHex(classification.rawPayload)}",
        )
        ProtectionRuntimeBridge.recordPlatformEvent(
            context = context,
            type = "sosEventReceived",
            reason =
                "remote:${classification.source.name}:${classification.relayNodeId}:${payloadHex(classification.rawPayload)}",
        )
    }

    private fun recordRemoteRelayEventPayload(
        classification: ProtectionBleSosIdentityClassification.RemoteEvent,
    ) {
        logSosTrace(
            "platform_event type=sosEventReceived originatorNodeId=${classification.originatorNodeId} " +
                "relayNodeId=${classification.relayNodeId} hasLocation=false " +
                "lat=none lon=none alt=none payloadHex=${payloadHex(classification.rawPayload)}",
        )
        ProtectionRuntimeBridge.recordBleEvent(
            context = context,
            type = "remoteRelaySosCancelReceived",
            reason =
                "originatorNodeId=${classification.originatorNodeId};relayNodeId=${classification.relayNodeId};source=${classification.source.name}",
        )
        ProtectionRuntimeBridge.recordPlatformEvent(
            context = context,
            type = "sosEventReceived",
            reason =
                "remote:${classification.source.name}:${classification.relayNodeId}:${payloadHex(classification.rawPayload)}",
        )
    }

    private fun payloadHex(payload: List<Int>): String =
        payload.joinToString(separator = "") { byte -> "%02x".format(byte) }

    private fun logSosPacketDecodeForTrace(
        payload: List<Int>,
        source: ProtectionBleSosRelaySource,
        classificationLabel: String,
    ) {
        if (payload.size != 7 && payload.size != 12) {
            if (classificationLabel == "notSos") {
                logSosTrace(
                    "native_sos_decode originatorNodeId=none " +
                        "connectedBleNodeId=${connectedBleNodeId ?: "none"} sosType=none " +
                        "classification=notSos hasLocation=false lat=none lon=none alt=none " +
                        "source=${source.name} payloadLen=${payload.size} payloadHex=${payloadHex(payload)}",
                )
            }
            return
        }
        val flagsOffset = if (payload.size == 12) 10 else 4
        val flagsWord = payload[flagsOffset] or (payload[flagsOffset + 1] shl 8)
        val sosType = (flagsWord shr 14) and 0x03
        val position = if (payload.size == 12) decodePositionForTrace(payload, 4) else null
        logSosTrace(
            "native_sos_decode originatorNodeId=${readU32OrNull(payload, 0) ?: "none"} " +
                "connectedBleNodeId=${connectedBleNodeId ?: "none"} sosType=$sosType " +
                "classification=$classificationLabel hasLocation=${position != null} " +
                "lat=${position?.latitude ?: "none"} lon=${position?.longitude ?: "none"} " +
                "alt=${position?.altitude ?: "none"} source=${source.name} " +
                "payloadLen=${payload.size} payloadHex=${payloadHex(payload)}",
        )
    }

    private fun decodePositionForTrace(payload: List<Int>, offset: Int): TracePosition {
        val packed =
            ((payload[offset] and 0xFF).toLong()) or
                ((payload[offset + 1] and 0xFF).toLong() shl 8) or
                ((payload[offset + 2] and 0xFF).toLong() shl 16) or
                ((payload[offset + 3] and 0xFF).toLong() shl 24) or
                ((payload[offset + 4] and 0xFF).toLong() shl 32) or
                ((payload[offset + 5] and 0xFF).toLong() shl 40)
        val latEnc = packed and 0xFFFFF
        val lonEnc = (packed shr 20) and 0x1FFFFF
        val altEnc = (packed shr 41) and 0x7F
        return TracePosition(
            latitude = (latEnc * 180.0 / 1048576.0) - 90.0,
            longitude = (lonEnc * 360.0 / 2097152.0) - 180.0,
            altitude = (altEnc * 40).toDouble(),
        )
    }

    private data class TracePosition(
        val latitude: Double,
        val longitude: Double,
        val altitude: Double,
    )

    private fun readU32OrNull(payload: List<Int>, offset: Int): Int? {
        if (payload.size < offset + 4) {
            return null
        }
        return (payload[offset] and 0xFF) or
            ((payload[offset + 1] and 0xFF) shl 8) or
            ((payload[offset + 2] and 0xFF) shl 16) or
            ((payload[offset + 3] and 0xFF) shl 24)
    }

    private fun logSosTrace(message: String) {
        Log.d("SOS_TRACE", "SOS_TRACE $message")
    }

    private fun observeSosLifecycle(payload: List<Int>) {
        if (payload.isEmpty()) {
            return
        }

        when (payload.size) {
            4, 6 -> {
                val opcode = payload[0] and 0xFF
                val subcode = payload[1] and 0xFF
                val closed = (opcode == 0xE1 && (subcode == 0x01 || subcode == 0x02)) ||
                    (opcode == 0xE2 && (subcode == 0x01 || subcode == 0x02 || subcode == 0x03))
                if (closed && pendingSosLifecycleState != ProtectionSosLifecycleState.idle) {
                    val closeOutcome =
                        ProtectionSosLifecycleLogic.onClosePacket(pendingSosLifecycleState)
                    pendingSosLifecycleState = closeOutcome.nextState
                    cancelSosActivationTimeout()
                    ProtectionForegroundService.showResolvedSosNotification(context)
                    if (closeOutcome.shouldCancelBackend) {
                        backendHandoff.queueCancel("device_cycle_closed")
                    }
                }
            }

            5, 7, 10, 12 -> {
                val nextState = ProtectionSosLifecycleLogic.onMeshPacket(pendingSosLifecycleState)
                if (nextState == ProtectionSosLifecycleState.preConfirmSeen &&
                    pendingSosLifecycleState != ProtectionSosLifecycleState.preConfirmSeen
                ) {
                    pendingSosLifecycleState = nextState
                    ProtectionForegroundService.showPreConfirmNotification(context)
                    scheduleSosActivationTimeout()
                }
            }
        }
    }

    private fun scheduleSosActivationTimeout() {
        sosActivationRunnable?.let(mainHandler::removeCallbacks)
        sosActivationRunnable = Runnable {
            val nextState =
                ProtectionSosLifecycleLogic.onCountdownElapsed(pendingSosLifecycleState)
            if (nextState == ProtectionSosLifecycleState.createPending &&
                pendingSosLifecycleState == ProtectionSosLifecycleState.preConfirmSeen
            ) {
                pendingSosLifecycleState = nextState
                ProtectionForegroundService.showActiveSosNotification(context)
                backendHandoff.queueCreate("device_cycle_active_after_timeout")
            }
            sosActivationRunnable = null
        }.also {
            mainHandler.postDelayed(it, sosActivationDelayMs)
        }
    }

    private fun cancelSosActivationTimeout() {
        sosActivationRunnable?.let(mainHandler::removeCallbacks)
        sosActivationRunnable = null
    }

    private val gattCallback =
        object : BluetoothGattCallback() {
            override fun onConnectionStateChange(
                gatt: BluetoothGatt,
                status: Int,
                newState: Int,
            ) {
                if (status != BluetoothGatt.GATT_SUCCESS &&
                    newState != BluetoothGatt.STATE_CONNECTED
                ) {
                    runtimeStore.markRuntimeFailure("Protection Mode GATT connection failed with status $status.")
                    ProtectionRuntimeBridge.recordBleEvent(
                        context = context,
                        type = "reconnectFailed",
                        reason = "gatt_status_$status",
                    )
                }
                when (newState) {
                    BluetoothGatt.STATE_CONNECTED -> {
                        connectionInFlight = false
                        reconnectAttemptCount = 0
                        runtimeStore.markServiceBleConnected()
                        ProtectionRuntimeBridge.recordBleEvent(
                            context = context,
                            type = "deviceConnected",
                            reason = "gatt_connected",
                        )
                        backendHandoff.flushPendingActions("gatt_connected")
                        discoverServices(gatt)
                    }

                    BluetoothGatt.STATE_DISCONNECTED -> {
                        connectionInFlight = false
                        runtimeStore.markServiceBleDisconnected()
                        ProtectionRuntimeBridge.recordBleEvent(
                            context = context,
                            type = "deviceDisconnected",
                            reason = "gatt_disconnected:$status",
                        )
                        if (!isStopping && runtimeActive) {
                            scheduleReconnect("gatt_disconnected")
                        }
                    }
                }
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    configureSubscriptions(gatt)
                } else {
                    connectionInFlight = false
                    runtimeStore.markRuntimeFailure("Protection Mode service discovery failed with status $status.")
                    ProtectionRuntimeBridge.recordPlatformEvent(
                        context = context,
                        type = "runtimeError",
                        reason = "services_discovered_status_$status",
                    )
                    scheduleReconnect("services_discovered_status_$status")
                }
            }

            override fun onDescriptorWrite(
                gatt: BluetoothGatt,
                descriptor: BluetoothGattDescriptor,
                status: Int,
            ) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    ProtectionRuntimeBridge.recordBleEvent(
                        context = context,
                        type = "reconnectFailed",
                        reason = "descriptor_write_status_$status",
                    )
                    scheduleReconnect("descriptor_write_status_$status")
                    return
                }

                when (subscriptionStep) {
                    SubscriptionStep.tel -> {
                        subscriptionStep = SubscriptionStep.sos
                        sosNotifyCharacteristic?.let {
                            enableCharacteristicNotifications(gatt, it)
                        }
                    }

                    SubscriptionStep.sos -> {
                        subscriptionStep = SubscriptionStep.complete
                        runtimeStore.markServiceBleReady()
                        ProtectionRuntimeBridge.recordBleEvent(
                            context = context,
                            type = "subscriptionsActive",
                            reason = "tel_and_sos_notifications_enabled",
                        )
                        ProtectionRuntimeBridge.recordPlatformEvent(
                            context = context,
                            type = "runtimeActive",
                            reason = "native_ble_runtime_ready",
                        )
                        backendHandoff.flushPendingActions("subscriptions_active")
                    }

                    SubscriptionStep.idle,
                    SubscriptionStep.complete,
                    -> Unit
                }
            }

            override fun onCharacteristicWrite(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                val pending = pendingCommandResult ?: return
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    val result =
                        "${pending.label} native write succeeded via androidService."
                    runtimeStore.recordCommandResult(result)
                    pending.complete(
                        result = result,
                    )
                } else {
                    runtimeStore.recordCommandError(
                        "${pending.label} native write failed with status $status.",
                    )
                    pending.fail(
                        error =
                            "${pending.label} native write failed with status $status.",
                    )
                }
                pendingCommandResult = null
            }

            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
            ) {
                handleIncomingPacket(characteristic, value)
            }

            @Deprecated("Deprecated in Java")
            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
            ) {
                handleIncomingPacket(characteristic, characteristic.value ?: ByteArray(0))
            }
        }

    private enum class SubscriptionStep {
        idle,
        tel,
        sos,
        complete,
    }

    companion object {
        private const val defaultReconnectBackoffMs = 5000L
        private const val inetMaxPayloadLength = 20
        private const val sosActivationDelayMs = 20_000L

        private val serviceUuid: UUID = UUID.fromString("6ba1b218-15a8-461f-9fa8-5dcae273ea00")
        private val telNotifyUuid: UUID = UUID.fromString("6ba1b218-15a8-461f-9fa8-5dcae273ea01")
        private val sosNotifyUuid: UUID = UUID.fromString("6ba1b218-15a8-461f-9fa8-5dcae273ea02")
        private val inetWriteUuid: UUID = UUID.fromString("6ba1b218-15a8-461f-9fa8-5dcae273ea03")
        private val cmdWriteUuid: UUID = UUID.fromString("6ba1b218-15a8-461f-9fa8-5dcae273ea04")
        private val clientCharacteristicConfigUuid: UUID =
            UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private fun commandResult(
        success: Boolean,
        route: String,
        result: String?,
        error: String?,
    ): Map<String, Any?> {
        return mapOf(
            "success" to success,
            "route" to route,
            "result" to result,
            "error" to error,
        )
    }

    private class PendingCommandResult(
        val label: String,
    ) {
        @Volatile
        var result: String? = null

        @Volatile
        var error: String? = null

        @Volatile
        var completed: Boolean = false

        fun complete(result: String) {
            this.result = result
            this.error = null
            this.completed = true
        }

        fun fail(error: String) {
            this.error = error
            this.completed = true
        }
    }
}
