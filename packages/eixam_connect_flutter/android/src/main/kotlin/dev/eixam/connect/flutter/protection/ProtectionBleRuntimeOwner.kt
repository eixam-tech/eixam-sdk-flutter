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
import android.os.SystemClock
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
    private val commandLock = Any()
    private val pendingCommandQueue = java.util.ArrayDeque<QueuedCommand>()
    private var pendingCommandResult: PendingCommandResult? = null
    private var connectedBleNodeId: Int? = null
    private var boundDeviceId: String? = null
    private var boundNodeId: Int? = null
    private val terminalSosSuppressionByKey = mutableMapOf<String, TerminalSosSuppression>()
    private val backendHandoff =
        ProtectionSosBackendHandoff(
            context = context,
            runtimeStore = runtimeStore,
            scheduleRetry = ::scheduleBackendFlush,
        )

    fun start(
        deviceId: String,
        backendHardwareId: String?,
        reconnectBackoffMs: Long,
        restored: Boolean,
    ) {
        if (runtimeActive && targetDeviceId == deviceId) {
            this.reconnectBackoffMs = reconnectBackoffMs.coerceAtLeast(1000L)
            bindDeviceIdentity(deviceId, backendHardwareId)
            ensureConnectedOrReconnect(
                reason = if (restored) "restored_runtime_reconnect" else "runtime_reconnect",
            )
            return
        }
        targetDeviceId = deviceId
        connectedBleNodeId = null
        terminalSosSuppressionByKey.clear()
        bindDeviceIdentity(deviceId, backendHardwareId)
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
        terminalSosSuppressionByKey.clear()
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
        if (label == "SOS CANCEL") {
            applyTerminalSosSuppression(
                reason = "native_terminal_command_${label.lowercase(Locale.US).replace(' ', '_')}",
                originatorNodeId = connectedBleNodeId ?: boundNodeId,
            )
        }
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

        val command =
            QueuedCommand(
                label = label,
                payload = payload.copyOf(),
                forceCmdCharacteristic = forceCmdCharacteristic,
                route = route,
            )
        synchronized(commandLock) {
            if (pendingCommandResult != null) {
                pendingCommandQueue.add(command)
                val result =
                    "$label native write queued via androidService because another BLE write is pending."
                runtimeStore.recordCommandResult(result)
                return commandResult(
                    success = true,
                    route = route,
                    result = result,
                    error = null,
                )
            }
        }
        return startCommandWrite(gatt, command, queued = false)
    }

    @SuppressLint("MissingPermission")
    private fun startCommandWrite(
        gatt: BluetoothGatt,
        command: QueuedCommand,
        queued: Boolean,
    ): Map<String, Any?> {
        val requiresLongCommandPath =
            command.forceCmdCharacteristic || command.payload.size > inetMaxPayloadLength
        val preferredCharacteristic =
            if (requiresLongCommandPath) {
                cmdWriteCharacteristic
            } else {
                inetWriteCharacteristic ?: cmdWriteCharacteristic
            }
        val characteristic =
            if (
                preferredCharacteristic == null &&
                command.forceCmdCharacteristic &&
                command.payload.size <= inetMaxPayloadLength &&
                command.payload.getOrNull(0)?.toInt()?.and(0xFF) == 0x04
            ) {
                logSosTrace(
                    "device_terminal_command_fallback channel=inet reason=cmd_not_ready",
                )
                inetWriteCharacteristic
            } else {
                preferredCharacteristic
            }

        if (characteristic == null) {
            val error =
                if (requiresLongCommandPath) {
                    "Protection Mode native BLE owner does not have CMD/EA04 ready for long command ${command.label}."
                } else {
                    "Protection Mode native BLE owner does not have a writable short command characteristic ready."
                }
            runtimeStore.recordCommandError(error)
            if (queued) {
                drainQueuedCommand(gatt)
            }
            Log.w(
                logTag,
                "[SDK_BLE_COMMAND] action=not_ready label=${command.label} error=$error",
            )
            return commandResult(
                success = false,
                route = command.route,
                result = null,
                error = error,
            )
        }

        synchronized(commandLock) {
            if (pendingCommandResult != null) {
                pendingCommandQueue.add(command)
                val result =
                    "${command.label} native write queued via androidService because another BLE write is pending."
                runtimeStore.recordCommandResult(result)
                return commandResult(
                    success = true,
                    route = command.route,
                    result = result,
                    error = null,
                )
            }
            pendingCommandResult = PendingCommandResult(label = command.label)
        }
        val writeAccepted =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(
                    characteristic,
                    command.payload,
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                ) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                run {
                    characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                    characteristic.value = command.payload
                    gatt.writeCharacteristic(characteristic)
                }
            }
        if (!writeAccepted) {
            synchronized(commandLock) {
                if (pendingCommandResult?.label == command.label) {
                    pendingCommandResult = null
                }
            }
            val error = "Android native BLE owner rejected the ${command.label} write request."
            runtimeStore.recordCommandError(error)
            Log.w(logTag, "[SDK_BLE_COMMAND] action=rejected label=${command.label}")
            drainQueuedCommand(gatt)
            return commandResult(
                success = false,
                route = command.route,
                result = null,
                error = error,
            )
        }
        if (command.payload.getOrNull(0)?.toInt()?.and(0xFF) == 0x04) {
            val terminalChannel =
                if (characteristic.uuid == cmdWriteUuid) "cmd" else "inet"
            logSosTrace(
                "device_terminal_command_sent opcode=0x04 channel=$terminalChannel",
            )
        }
        val result =
            if (queued) {
                "${command.label} queued native write accepted via androidService."
            } else {
                "${command.label} native write accepted via androidService."
            }
        runtimeStore.recordCommandResult(result)
        return commandResult(
            success = true,
            route = command.route,
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
        bindDeviceIdentity(deviceId, runtimeStore.currentBackendHardwareId())
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
            if (!isBondedDevice(adapter, deviceId)) {
                connectionInFlight = false
                val failureReason =
                    "E_DEVICE_MOBILE_BOND_REQUIRED: The device is no longer paired in the phone Bluetooth settings."
                runtimeStore.markRuntimeFailure(failureReason)
                ProtectionRuntimeBridge.recordBleEvent(
                    context = context,
                    type = "reconnectFailed",
                    reason = "mobile_bond_missing",
                )
                return
            }
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
    private fun isBondedDevice(
        adapter: android.bluetooth.BluetoothAdapter,
        deviceId: String,
    ): Boolean {
        return try {
            adapter.bondedDevices.any { device ->
                device.address.equals(deviceId, ignoreCase = true)
            }
        } catch (_: SecurityException) {
            true
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
        clearPendingCommandWrites()
    }

    private fun clearPendingCommandWrites() {
        synchronized(commandLock) {
            pendingCommandResult = null
            pendingCommandQueue.clear()
        }
    }

    private fun drainQueuedCommand(gatt: BluetoothGatt) {
        val next =
            synchronized(commandLock) {
                if (pendingCommandResult == null) {
                    pendingCommandQueue.pollFirst()
                } else {
                    null
                }
            } ?: return
        mainHandler.post {
            if (bluetoothGatt !== gatt) {
                runtimeStore.recordCommandError(
                    "${next.label} queued native write dropped because the BLE session changed.",
                )
                Log.w(
                    logTag,
                    "[SDK_BLE_COMMAND] action=dropped label=${next.label} reason=session_changed",
                )
                drainQueuedCommand(gatt)
                return@post
            }
            startCommandWrite(gatt, next, queued = true)
        }
    }

    private fun bindDeviceIdentity(
        deviceId: String?,
        backendHardwareId: String?,
        learnedNodeId: Int? = null,
    ) {
        boundDeviceId = deviceId
        boundNodeId = learnedNodeId
            ?: nodeIdFromTrustedMac(backendHardwareId)
            ?: nodeIdFromTrustedMac(deviceId)
            ?: runtimeStore.currentBoundNodeId()
        runtimeStore.saveBoundDeviceIdentity(boundDeviceId, boundNodeId)
    }

    private fun fallbackNodeIdFor(payload: List<Int>): Int? {
        val fallback = if (connectedBleNodeId == null) boundNodeId else null
        val originatorNodeId = readPacketOriginatorNodeId(payload)
        val result = when {
            connectedBleNodeId != null -> "no_match" to "connected_node_available"
            fallback == null -> "no_match" to "bound_node_unavailable"
            originatorNodeId == null -> "no_match" to "originator_unavailable"
            originatorNodeId == fallback -> "matched_bound_device" to "originator_matches_bound_node"
            else -> "no_match" to "originator_differs_from_bound_node"
        }
        logSosTrace(
            "native_identity_fallback result=${result.first} reason=${result.second}",
        )
        if (connectedBleNodeId == null && originatorNodeId != null) {
            logSosTrace(
                "native_identity_fallback proof=metadata_only " +
                    "originatorNodeId=$originatorNodeId boundNodeId=${boundNodeId ?: "none"} " +
                    "reason=connected_identity_unknown_fail_closed",
            )
        }
        return fallback
    }

    private fun logIdentityState(
        sourceLabel: String,
        activeBleHardwareId: String?,
        bleLinkActive: Boolean,
    ) {
        logSosTrace(
            "native_identity_state connectedBleNodeId=${connectedBleNodeId ?: "none"} " +
                "boundDeviceId=${boundDeviceId ?: "none"} boundNodeId=${boundNodeId ?: "none"} " +
                "activeBleHardwareId=${activeBleHardwareId ?: "none"} " +
                "bleLinkActive=$bleLinkActive cmdReady=${cmdWriteCharacteristic != null} " +
                "source=$sourceLabel",
        )
    }

    @SuppressLint("MissingPermission")
    private fun handleIncomingPacket(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        rawBytes: ByteArray,
    ) {
        val payload = rawBytes.map { byte -> byte.toInt() and 0xFF }
        val activeBleHardwareId = gatt.device?.address
        val bleLinkActive = runtimeActive &&
            !isStopping &&
            bluetoothGatt === gatt &&
            runtimeStore.snapshot()["serviceBleConnected"] == true
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
        logIdentityState(sourceLabel, activeBleHardwareId, bleLinkActive)
        runtimeStore.recordPacket(payload)
        ProtectionRuntimeBridge.recordBleEvent(
            context = context,
            type = "packetReceived",
            reason = "${characteristic.uuid}:${payload.size}",
        )

        if (characteristic.uuid == telNotifyUuid) {
            ProtectionBleSosIdentityClassifier.tryParseDeviceRuntimeNodeId(payload)?.let { nodeId ->
                connectedBleNodeId = nodeId
                bindDeviceIdentity(targetDeviceId, runtimeStore.currentBackendHardwareId(), nodeId)
                ProtectionRuntimeBridge.recordBleEvent(
                    context = context,
                    type = "deviceRuntimeStatusReceived",
                    reason = "nodeId=$nodeId",
                )
            }
            if (payload.size == 27 && payload.firstOrNull() == 0xD2) {
                val peerPayload = payload.subList(1, 13).toList()
                val selfPayload = payload.subList(15, 27).toList()
                if (connectedBleNodeId == null) {
                    readU32OrNull(selfPayload, 0)?.let { selfNodeId ->
                        connectedBleNodeId = selfNodeId
                        bindDeviceIdentity(targetDeviceId, runtimeStore.currentBackendHardwareId(), selfNodeId)
                    }
                }
                fallbackNodeIdFor(peerPayload)
                when (
                    val classification = ProtectionBleSosIdentityClassifier.classify(
                        payload = peerPayload,
                        connectedNodeId = connectedBleNodeId,
                        boundNodeId = boundNodeId,
                        boundDeviceId = boundDeviceId,
                        activeBleHardwareId = activeBleHardwareId,
                        activeRuntimeDeviceId = targetDeviceId,
                        bleLinkActive = bleLinkActive,
                        cmdReady = cmdWriteCharacteristic != null,
                        source = ProtectionBleSosRelaySource.d2,
                    )
                ) {
                    is ProtectionBleSosIdentityClassification.RemoteSos -> {
                        recordRemoteRelaySosPayload(classification, activeBleHardwareId, bleLinkActive)
                        return
                    }

                    is ProtectionBleSosIdentityClassification.UnknownOriginSos -> {
                        recordUnknownOriginSosPayload(classification, activeBleHardwareId, bleLinkActive)
                        return
                    }

                    is ProtectionBleSosIdentityClassification.UnknownOriginEvent -> {
                        recordUnknownOriginEventPayload(classification, activeBleHardwareId, bleLinkActive)
                        return
                    }

                    else -> Unit
                }
            }
            fallbackNodeIdFor(payload)
            when (
                val classification = ProtectionBleSosIdentityClassifier.classify(
                    payload = payload,
                    connectedNodeId = connectedBleNodeId,
                    boundNodeId = boundNodeId,
                    boundDeviceId = boundDeviceId,
                    activeBleHardwareId = activeBleHardwareId,
                    activeRuntimeDeviceId = targetDeviceId,
                    bleLinkActive = bleLinkActive,
                    cmdReady = cmdWriteCharacteristic != null,
                    source = ProtectionBleSosRelaySource.tel,
                )
            ) {
                is ProtectionBleSosIdentityClassification.RemoteSos -> {
                    recordRemoteRelaySosPayload(classification, activeBleHardwareId, bleLinkActive)
                    return
                }

                is ProtectionBleSosIdentityClassification.UnknownOriginSos -> {
                    recordUnknownOriginSosPayload(classification, activeBleHardwareId, bleLinkActive)
                    return
                }

                is ProtectionBleSosIdentityClassification.UnknownOriginEvent -> {
                    recordUnknownOriginEventPayload(classification, activeBleHardwareId, bleLinkActive)
                    return
                }

                is ProtectionBleSosIdentityClassification.RemoteEvent -> {
                    recordRemoteRelayEventPayload(classification, activeBleHardwareId, bleLinkActive)
                    return
                }

                is ProtectionBleSosIdentityClassification.OwnSos -> {
                    recordSosIdentityDecision(
                        originatorNodeId = readPacketOriginatorNodeId(payload),
                        relayNodeId = connectedBleNodeId,
                        source = ProtectionBleSosRelaySource.tel,
                        platformEventType = null,
                        decision = "own_device",
                        reason = classification.reason,
                        activeBleHardwareId = activeBleHardwareId,
                        bleLinkActive = bleLinkActive,
                        identityProof = classification.identityProof,
                    )
                    logSosPacketDecodeForTrace(
                        payload = payload,
                        source = ProtectionBleSosRelaySource.tel,
                        classificationLabel = "ownDeviceSos",
                    )
                    if (shouldSuppressRecentTerminalOwnSosPacket(payload)) {
                        return
                    }
                    logSosTrace(
                        "native_lifecycle_gate classification=ownDeviceSos " +
                            "action=observe_local_lifecycle observeSosLifecycle_called=true",
                    )
                    ProtectionRuntimeBridge.recordBleEvent(
                        context = context,
                        type = "telDerivedSosReceived",
                        reason = payloadHex(payload),
                    )
                    observeSosLifecycle(payload)
                    return
                }

                is ProtectionBleSosIdentityClassification.OwnEvent -> {
                    recordSosIdentityDecision(
                        originatorNodeId = readPacketOriginatorNodeId(payload),
                        relayNodeId = connectedBleNodeId,
                        source = ProtectionBleSosRelaySource.tel,
                        platformEventType = null,
                        decision = "own_device",
                        reason = classification.reason,
                        activeBleHardwareId = activeBleHardwareId,
                        bleLinkActive = bleLinkActive,
                        identityProof = classification.identityProof,
                    )
                    if (shouldSuppressRecentTerminalOwnSosPacket(payload)) {
                        return
                    }
                    logSosTrace(
                        "native_lifecycle_gate classification=ownDeviceSos " +
                            "action=observe_local_lifecycle observeSosLifecycle_called=true",
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
            fallbackNodeIdFor(payload)
            val classification = ProtectionBleSosIdentityClassifier.classify(
                payload = payload,
                connectedNodeId = connectedBleNodeId,
                boundNodeId = boundNodeId,
                boundDeviceId = boundDeviceId,
                activeBleHardwareId = activeBleHardwareId,
                activeRuntimeDeviceId = targetDeviceId,
                bleLinkActive = bleLinkActive,
                cmdReady = cmdWriteCharacteristic != null,
                source = ProtectionBleSosRelaySource.sos,
            )
            when (classification) {
                is ProtectionBleSosIdentityClassification.RemoteSos -> {
                    recordRemoteRelaySosPayload(classification, activeBleHardwareId, bleLinkActive)
                    return
                }

                is ProtectionBleSosIdentityClassification.UnknownOriginSos -> {
                    recordUnknownOriginSosPayload(classification, activeBleHardwareId, bleLinkActive)
                    return
                }

                is ProtectionBleSosIdentityClassification.UnknownOriginEvent -> {
                    recordUnknownOriginEventPayload(classification, activeBleHardwareId, bleLinkActive)
                    return
                }

                is ProtectionBleSosIdentityClassification.RemoteEvent -> {
                    recordRemoteRelayEventPayload(classification, activeBleHardwareId, bleLinkActive)
                    return
                }

                else -> Unit
            }
            logSosPacketDecodeForTrace(
                payload = payload,
                source = ProtectionBleSosRelaySource.sos,
                classificationLabel =
                    if (classification is ProtectionBleSosIdentityClassification.OwnSos ||
                        classification is ProtectionBleSosIdentityClassification.OwnEvent
                    ) {
                        "ownDeviceSos"
                    } else {
                        "notSos"
                    },
            )
            if (classification !is ProtectionBleSosIdentityClassification.OwnSos &&
                classification !is ProtectionBleSosIdentityClassification.OwnEvent &&
                readPacketOriginatorNodeId(payload) != null
            ) {
                return
            }
            val nativeRoute = ProtectionBleSosNativeRouting.route(classification)
            if (!nativeRoute.observeLocalLifecycle) {
                return
            }
            ProtectionRuntimeBridge.recordBleEvent(
                context = context,
                type = nativeRoute.diagnosticEventType ?: "ownDeviceSosLifecycleObserved",
                reason = "own:${ProtectionBleSosRelaySource.sos.name}:${payloadHex(payload)}",
            )
            recordSosIdentityDecision(
                originatorNodeId = readPacketOriginatorNodeId(payload),
                relayNodeId = connectedBleNodeId,
                source = ProtectionBleSosRelaySource.sos,
                platformEventType = nativeRoute.diagnosticEventType ?: "ownDeviceSosLifecycleObserved",
                decision = "own_device",
                reason = classification.reason,
                activeBleHardwareId = activeBleHardwareId,
                bleLinkActive = bleLinkActive,
                identityProof = classification.identityProof,
            )
            if (shouldSuppressRecentTerminalOwnSosPacket(payload)) {
                return
            }
            logSosTrace(
                "native_lifecycle_gate classification=ownDeviceSos " +
                    "action=observe_local_lifecycle observeSosLifecycle_called=true",
            )
            observeSosLifecycle(payload)
        }
    }

    private fun recordUnknownOriginSosPayload(
        classification: ProtectionBleSosIdentityClassification.UnknownOriginSos,
        activeBleHardwareId: String?,
        bleLinkActive: Boolean,
    ) {
        recordSosIdentityDecision(
            originatorNodeId = classification.originatorNodeId,
            relayNodeId = null,
            source = classification.source,
            platformEventType = "sosEventReceived",
            decision = "unknown_hold",
            reason = classification.reason,
            activeBleHardwareId = activeBleHardwareId,
            bleLinkActive = bleLinkActive,
            identityProof = classification.identityProof,
        )
        logSosTrace(
            "native_sos_decode originatorNodeId=${classification.originatorNodeId} " +
                "strictConnectedBleNodeId=${connectedBleNodeId ?: "none"} boundNodeId=${boundNodeId ?: "none"} " +
                "sosType=${classification.sosType} " +
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

    private fun recordUnknownOriginEventPayload(
        classification: ProtectionBleSosIdentityClassification.UnknownOriginEvent,
        activeBleHardwareId: String?,
        bleLinkActive: Boolean,
    ) {
        recordSosIdentityDecision(
            originatorNodeId = classification.originatorNodeId,
            relayNodeId = null,
            source = classification.source,
            platformEventType = "sosEventReceived",
            decision = "unknown_hold",
            reason = classification.reason,
            activeBleHardwareId = activeBleHardwareId,
            bleLinkActive = bleLinkActive,
            identityProof = classification.identityProof,
        )
        logSosTrace(
            "native_sos_event_decode originatorNodeId=${classification.originatorNodeId} " +
                "strictConnectedBleNodeId=${connectedBleNodeId ?: "none"} boundNodeId=${boundNodeId ?: "none"} " +
                "classification=unknownOriginEvent source=${classification.source.name} " +
                "payloadLen=${classification.rawPayload.size} payloadHex=${payloadHex(classification.rawPayload)}",
        )
        ProtectionRuntimeBridge.recordBleEvent(
            context = context,
            type = "unknownOriginSosEventReceived",
            reason =
                "originatorNodeId=${classification.originatorNodeId};source=${classification.source.name}",
        )
        logSosTrace(
            "native_lifecycle_gate classification=unknownOriginEvent " +
                "action=skip_unknown_identity observeSosLifecycle_called=false",
        )
        logSosTrace(
            "platform_event type=sosEventReceived originatorNodeId=${classification.originatorNodeId} " +
                "relayNodeId=none hasLocation=false lat=none lon=none alt=none " +
                "payloadHex=${payloadHex(classification.rawPayload)}",
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
        activeBleHardwareId: String?,
        bleLinkActive: Boolean,
    ) {
        recordSosIdentityDecision(
            originatorNodeId = classification.originatorNodeId,
            relayNodeId = classification.relayNodeId,
            source = classification.source,
            platformEventType = "sosEventReceived",
            decision = "remote_relay",
            reason = classification.reason,
            activeBleHardwareId = activeBleHardwareId,
            bleLinkActive = bleLinkActive,
            identityProof = classification.identityProof,
        )
        logSosTrace(
            "native_sos_decode originatorNodeId=${classification.originatorNodeId} " +
                "connectedBleNodeId=${connectedBleNodeId ?: "none"} boundNodeId=${boundNodeId ?: "none"} " +
                "sosType=${classification.sosType} " +
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
        activeBleHardwareId: String?,
        bleLinkActive: Boolean,
    ) {
        recordSosIdentityDecision(
            originatorNodeId = classification.originatorNodeId,
            relayNodeId = classification.relayNodeId,
            source = classification.source,
            platformEventType = "sosEventReceived",
            decision = "remote_relay",
            reason = classification.reason,
            activeBleHardwareId = activeBleHardwareId,
            bleLinkActive = bleLinkActive,
            identityProof = classification.identityProof,
        )
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

    private fun applyTerminalSosSuppression(
        reason: String,
        originatorNodeId: Int? = null,
    ) {
        val now = SystemClock.elapsedRealtime()
        pruneTerminalSosSuppressions(now)
        val effectiveNodeId = originatorNodeId ?: connectedBleNodeId ?: boundNodeId
        val keys = terminalSuppressionKeys(effectiveNodeId, boundDeviceId)
        if (keys.isEmpty()) {
            return
        }
        val suppression = TerminalSosSuppression(
            originatorNodeId = effectiveNodeId,
            boundDeviceId = boundDeviceId,
            expiresAtMs = now + terminalSosSuppressionWindowMs,
            reason = reason,
        )
        keys.forEach { key -> terminalSosSuppressionByKey[key] = suppression }
        logSosTrace(
            "terminal_suppression_applied reason=$reason " +
                "originatorNodeId=${effectiveNodeId ?: "none"} " +
                "boundDeviceId=${boundDeviceId ?: "none"}",
        )
    }

    private fun shouldSuppressRecentTerminalOwnSosPacket(payload: List<Int>): Boolean {
        val now = SystemClock.elapsedRealtime()
        pruneTerminalSosSuppressions(now)
        val originatorNodeId = readPacketOriginatorNodeId(payload)
        val keys = terminalSuppressionKeys(originatorNodeId, boundDeviceId)
        for (key in keys) {
            val suppression = terminalSosSuppressionByKey[key] ?: continue
            if (now > suppression.expiresAtMs) {
                continue
            }
            logSosTrace(
                "terminal_suppression_applied reason=recent_terminal_action " +
                    "originatorNodeId=${originatorNodeId ?: "none"} " +
                    "boundDeviceId=${boundDeviceId ?: "none"} " +
                    "suppressionReason=${suppression.reason}",
            )
            logSosTrace(
                "native_lifecycle_gate classification=ownDeviceSos " +
                    "action=suppress_recent_terminal observeSosLifecycle_called=false",
            )
            ProtectionRuntimeBridge.recordBleEvent(
                context = context,
                type = "ownDeviceSosLifecycleSuppressed",
                reason =
                    "recent_terminal_action:" +
                        "${originatorNodeId ?: "none"}:" +
                        "${boundDeviceId ?: "none"}:${payloadHex(payload)}",
            )
            return true
        }
        return false
    }

    private fun terminalSuppressionKeys(
        originatorNodeId: Int?,
        boundDeviceId: String?,
    ): List<String> {
        if (originatorNodeId != null) {
            return listOf("node:$originatorNodeId")
        }
        if (!boundDeviceId.isNullOrBlank()) {
            return listOf("device:$boundDeviceId")
        }
        return emptyList()
    }

    private fun pruneTerminalSosSuppressions(nowMs: Long) {
        terminalSosSuppressionByKey.entries.removeIf { entry ->
            nowMs > entry.value.expiresAtMs
        }
    }

    private fun payloadHex(payload: List<Int>): String =
        payload.joinToString(separator = "") { byte -> "%02x".format(byte) }

    private fun recordSosIdentityDecision(
        originatorNodeId: Int?,
        relayNodeId: Int?,
        source: ProtectionBleSosRelaySource,
        platformEventType: String?,
        decision: String,
        reason: String,
        activeBleHardwareId: String? = null,
        bleLinkActive: Boolean =
            runtimeActive &&
                !isStopping &&
                runtimeStore.snapshot()["serviceBleConnected"] == true,
        identityProof: IdentityProof = IdentityProof.None,
    ) {
        logSosTrace(
            "sos_identity_decision originatorNodeId=${originatorNodeId ?: "none"} " +
                "strictConnectedBleNodeId=${connectedBleNodeId ?: "none"} " +
                "boundNodeId=${boundNodeId ?: "none"} " +
                "boundDeviceId=${boundDeviceId ?: "none"} " +
                "activeBleHardwareId=${activeBleHardwareId ?: "none"} " +
                "bleLinkActive=$bleLinkActive cmdReady=${cmdWriteCharacteristic != null} " +
                "relayNodeId=${relayNodeId ?: "none"} sourceChannel=${source.name} " +
                "platformEventType=${platformEventType ?: "none"} " +
                "decision=$decision reason=$reason identityProof=${identityProof.logValue}",
        )
    }

    private fun readPacketOriginatorNodeId(payload: List<Int>): Int? {
        if (payload.size == 6 && (payload[0] == 0xE1 || payload[0] == 0xE2)) {
            return readU32OrNull(payload, 2)
        }
        if (payload.size == 7 || payload.size == 12) {
            return readU32OrNull(payload, 0)
        }
        return null
    }

    private fun logSosPacketDecodeForTrace(
        payload: List<Int>,
        source: ProtectionBleSosRelaySource,
        classificationLabel: String,
    ) {
        if (payload.size != 7 && payload.size != 12) {
            if (classificationLabel == "notSos") {
                logSosTrace(
                    "native_sos_decode originatorNodeId=none " +
                        "connectedBleNodeId=${connectedBleNodeId ?: "none"} boundNodeId=${boundNodeId ?: "none"} " +
                        "sosType=none " +
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
                "connectedBleNodeId=${connectedBleNodeId ?: "none"} boundNodeId=${boundNodeId ?: "none"} " +
                "sosType=$sosType " +
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

    private fun nodeIdFromTrustedMac(value: String?): Int? {
        val normalized = value?.trim()?.uppercase(Locale.US) ?: return null
        if (!macAddressPattern.matches(normalized)) {
            return null
        }
        val parts = normalized.split(":")
        return (parts[2].toInt(16) shl 24) or
            (parts[3].toInt(16) shl 16) or
            (parts[4].toInt(16) shl 8) or
            parts[5].toInt(16)
    }

    private fun logSosTrace(message: String) {
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
                if (closed) {
                    applyTerminalSosSuppression(
                        reason = "own_device_terminal_packet",
                        originatorNodeId = readPacketOriginatorNodeId(payload),
                    )
                }
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
                val pending =
                    synchronized(commandLock) {
                        pendingCommandResult
                    } ?: return
                val terminalCancelSucceeded =
                    status == BluetoothGatt.GATT_SUCCESS && pending.label == "SOS CANCEL"
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
                    Log.w(
                        logTag,
                        "[SDK_BLE_COMMAND] action=failed label=${pending.label} status=$status",
                    )
                    pending.fail(
                        error =
                            "${pending.label} native write failed with status $status.",
                    )
                }
                synchronized(commandLock) {
                    if (pendingCommandResult === pending) {
                        pendingCommandResult = null
                    }
                }
                if (terminalCancelSucceeded) {
                    stop("sos_cancel_command_succeeded")
                    runtimeStore.markStopped()
                    ProtectionForegroundService.stop(context)
                    return
                }
                drainQueuedCommand(gatt)
            }

            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
            ) {
                handleIncomingPacket(gatt, characteristic, value)
            }

            @Deprecated("Deprecated in Java")
            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
            ) {
                handleIncomingPacket(gatt, characteristic, characteristic.value ?: ByteArray(0))
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
        private const val inetMaxPayloadLength = 4
        private const val sosActivationDelayMs = 20_000L
        private const val terminalSosSuppressionWindowMs = 10_000L
        private const val logTag = "EixamProtectionBle"

        private val serviceUuid: UUID = UUID.fromString("6ba1b218-15a8-461f-9fa8-5dcae273ea00")
        private val telNotifyUuid: UUID = UUID.fromString("6ba1b218-15a8-461f-9fa8-5dcae273ea01")
        private val sosNotifyUuid: UUID = UUID.fromString("6ba1b218-15a8-461f-9fa8-5dcae273ea02")
        private val inetWriteUuid: UUID = UUID.fromString("6ba1b218-15a8-461f-9fa8-5dcae273ea03")
        private val cmdWriteUuid: UUID = UUID.fromString("6ba1b218-15a8-461f-9fa8-5dcae273ea04")
        private val clientCharacteristicConfigUuid: UUID =
            UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private val macAddressPattern =
            Regex("^([0-9A-F]{2}:){5}[0-9A-F]{2}$")
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

    private data class QueuedCommand(
        val label: String,
        val payload: ByteArray,
        val forceCmdCharacteristic: Boolean,
        val route: String,
    )

    private data class TerminalSosSuppression(
        val originatorNodeId: Int?,
        val boundDeviceId: String?,
        val expiresAtMs: Long,
        val reason: String,
    )
}
