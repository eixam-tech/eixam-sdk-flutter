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
    private var gattSessionGeneration: Long = 0
    private var serviceDiscoveryTimeoutRunnable: Runnable? = null
    private var skipGattCacheRefreshForNextSession = false
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
    private var eixamServiceReady = false
    private var commandQueueHealthy = true
    private var lastPublishedCommandReadiness: ProtectionNativeCommandReadiness? = null
    private var subscriptionStep = SubscriptionStep.idle
    private var pendingSosLifecycleState = ProtectionSosLifecycleState.idle
    private var sosActivationRunnable: Runnable? = null
    /** F17b: the SDK closed an SOS the TAG may still be running (persisted). */
    private var sosStaleGuard: ProtectionSosStaleGuardState? = runtimeStore.loadSosStaleGuard()
    private var sosStaleDecideRunnable: Runnable? = null
    /** F17c: an SOS native saw only through Dart's forwarded frames (persisted). */
    private var sosObservedCycle: ProtectionSosObservedCycle? = runtimeStore.loadSosObservedCycle()
    /** One lock for the native SOS lifecycle, its activation timer and the stale guard (M3). */
    private val sosLifecycleLock = Any()
    private var backendRetryRunnable: Runnable? = null
    private var connectionInFlight = false
    private val commandLock = Any()
    private val pendingCommandQueue = java.util.ArrayDeque<QueuedCommand>()
    private var pendingCommandResult: PendingCommandResult? = null
    private var connectedBleNodeId: Int? = null
    private var notificationReceiveSequence: Long = 0
    private var boundDeviceId: String? = null
    private var boundNodeId: Int? = null
    private val backendHandoff =
        ProtectionSosBackendHandoff(
            context = context,
            runtimeStore = runtimeStore,
            scheduleRetry = ::scheduleBackendFlush,
        )

    /** The SDK's MQTT outbox accepted the TAG cancel: retire the native record. */
    fun ackPendingNativeSosCancel(): Boolean = backendHandoff.ackPendingCancelHandedToMqtt()

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
        rehydratePreSosLifecycle(reason = if (restored) "restored_runtime" else "runtime_start")
        connect(reason = if (restored) "restored_runtime_connect" else "runtime_connect")
    }

    fun stop(reason: String) {
        isStopping = true
        runtimeActive = false
        reconnectRunnable?.let(mainHandler::removeCallbacks)
        serviceDiscoveryTimeoutRunnable?.let(mainHandler::removeCallbacks)
        backendRetryRunnable?.let(mainHandler::removeCallbacks)
        sosActivationRunnable?.let(mainHandler::removeCallbacks)
        reconnectRunnable = null
        serviceDiscoveryTimeoutRunnable = null
        skipGattCacheRefreshForNextSession = false
        backendRetryRunnable = null
        sosActivationRunnable = null
        subscriptionStep = SubscriptionStep.idle
        synchronized(sosLifecycleLock) {
            pendingSosLifecycleState = ProtectionSosLifecycleState.idle
            runtimeStore.clearPreSosLifecycle()
        }
        markSosStaleGuardLinkDropped("runtime_stop_$reason")
        connectedBleNodeId = null
        clearCharacteristicRefs()
        closeCurrentGattSession(reason)
        runtimeStore.markServiceBleDisconnected()
        publishNativeCommandReadiness(reason = reason, force = true)
        ProtectionRuntimeBridge.recordBleEvent(
            context = context,
            type = "deviceDisconnected",
            reason = reason,
        )
    }

    fun isRunning(): Boolean = runtimeActive

    fun isRunningFor(deviceId: String): Boolean =
        runtimeActive && targetDeviceId == deviceId

    fun refreshCommandReadinessForBridgeAttachment(bridgeGeneration: Long) {
        publishNativeCommandReadiness(
            reason = "flutter_bridge_attached_$bridgeGeneration",
            force = true,
        )
    }

    fun flushPendingBackendActions(reason: String): Map<String, Any> =
        backendHandoff.flushPendingActionsSync(reason)

    fun ensureConnectedOrReconnect(reason: String, force: Boolean = false) {
        if (!runtimeActive || isStopping || targetDeviceId.isNullOrBlank()) {
            return
        }
        if (force) {
            reconnectRunnable?.let(mainHandler::removeCallbacks)
            reconnectRunnable = null
            connectionInFlight = false
            connect(reason = reason)
            return
        }
        if (bluetoothGatt != null && lastPublishedCommandReadiness?.ready == true) {
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
        completion: (Map<String, Any?>) -> Unit,
    ) {
        val route = "androidService"
        Log.i(
            logTag,
            "SOS_CANCEL_NATIVE_SERVICE_RECEIVED label=$label " +
                "runtimeActive=$runtimeActive gattAvailable=${bluetoothGatt != null}",
        )
        runtimeStore.recordCommandRoute(route)
        if (!runtimeActive) {
            val error = "Protection Mode native BLE owner is not active."
            runtimeStore.recordCommandError(error)
            completion(
                commandResult(
                    success = false,
                    route = route,
                    result = null,
                    error = error,
                ),
            )
            return
        }
        val gatt = bluetoothGatt
        val serviceBleConnected =
            runtimeStore.snapshot()["serviceBleConnected"] as? Boolean ?: false
        if (gatt == null || !serviceBleConnected) {
            val error =
                "Protection Mode native BLE owner is not connected to the protected device."
            runtimeStore.recordCommandError(error)
            ensureConnectedOrReconnect("native_command_$label")
            completion(
                commandResult(
                    success = false,
                    route = route,
                    result = null,
                    error = error,
                ),
            )
            return
        }
        Log.i(
            logTag,
            "SOS_CANCEL_NATIVE_GATT_AVAILABLE label=$label available=true",
        )

        val command =
            QueuedCommand(
                label = label,
                payload = payload.copyOf(),
                forceCmdCharacteristic = forceCmdCharacteristic,
                route = route,
                completion = completion,
            )
        synchronized(commandLock) {
            if (pendingCommandResult != null) {
                pendingCommandQueue.add(command)
                val result =
                    "$label native write queued via androidService because another BLE write is pending."
                runtimeStore.recordCommandResult(result)
                return
            }
        }
        startCommandWrite(gatt, command, queued = false)
    }

    @SuppressLint("MissingPermission")
    private fun startCommandWrite(
        gatt: BluetoothGatt,
        command: QueuedCommand,
        queued: Boolean,
    ) {
        val opcode = command.payload.getOrNull(0)?.toInt()?.and(0xFF)
        val requiresLongCommandPath =
            command.forceCmdCharacteristic || command.payload.size > inetMaxPayloadLength
        val selectedRole =
            ProtectionGattWritePolicy.selectCharacteristic(
                forceCmdCharacteristic = command.forceCmdCharacteristic,
                payloadLength = command.payload.size,
                opcode = opcode,
                inetReady = inetWriteCharacteristic != null,
                cmdReady = cmdWriteCharacteristic != null,
                inetMaxPayloadLength = inetMaxPayloadLength,
            )
        val characteristic = when (selectedRole) {
            ProtectionGattCharacteristicRole.inet -> inetWriteCharacteristic
            ProtectionGattCharacteristicRole.cmd -> cmdWriteCharacteristic
            null -> null
        }
        if (
            selectedRole == ProtectionGattCharacteristicRole.inet &&
            command.forceCmdCharacteristic
        ) {
            logSosTrace(
                "device_command_fallback channel=inet " +
                    "opcode=${opcode?.let(::formatOpcode) ?: "none"} reason=cmd_not_ready",
            )
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
            command.completion(
                commandResult(
                    success = false,
                    route = command.route,
                    result = null,
                    error = error,
                ),
            )
            return
        }
        Log.i(
            logTag,
            "SOS_CANCEL_NATIVE_CHARACTERISTIC_AVAILABLE label=${command.label} " +
                "available=true role=${selectedRole?.name ?: "none"}",
        )

        val supportsWrite =
            characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0
        val supportsWriteWithoutResponse =
            characteristic.properties and
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0
        val writeType = ProtectionGattWritePolicy.selectWriteWithResponse(
            supportsWrite = supportsWrite,
            supportsWriteWithoutResponse = supportsWriteWithoutResponse,
        )?.let { withResponse ->
            if (withResponse) {
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            } else {
                BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            }
        }
        if (writeType == null) {
            val error =
                "Protection Mode selected ${characteristic.uuid} for ${command.label}, but it is not writable."
            runtimeStore.recordCommandError(error)
            recordGattWriteResult(
                command = command,
                characteristic = characteristic,
                writeType = null,
                success = false,
                status = "characteristic_not_writable",
            )
            command.completion(
                commandResult(
                    success = false,
                    route = command.route,
                    result = null,
                    error = error,
                ),
            )
            invalidateCommandPathAndReconnect(gatt, "characteristic_not_writable")
            return
        }

        val pending =
            PendingCommandResult(
                command = command,
                gatt = gatt,
                characteristicUuid = characteristic.uuid,
                writeType = writeType,
            )
        synchronized(commandLock) {
            if (pendingCommandResult != null) {
                pendingCommandQueue.add(command)
                val result =
                    "${command.label} native write queued via androidService because another BLE write is pending."
                runtimeStore.recordCommandResult(result)
                return
            }
            pendingCommandResult = pending
        }
        val target = redactDeviceTarget(targetDeviceId)
        Log.i(
            logTag,
            "EIXAM_COMMAND_WRITE source=native_protection " +
                "opcode=${opcode?.let(::formatOpcode) ?: "none"} " +
                "byteLength=${command.payload.size} characteristic=${characteristic.uuid} " +
                "target=$target",
        )
        Log.i(
            logTag,
            "SOS_CANCEL_NATIVE_WRITE_ATTEMPTED label=${command.label} " +
                "characteristic=${characteristic.uuid}",
        )
        val nativeMethod = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            "BluetoothGatt.writeCharacteristic(characteristic,payload,writeType)"
        } else {
            "BluetoothGatt.writeCharacteristic(characteristic)"
        }
        if (opcode in sosCommandOpcodes) {
            Log.i(
                logTag,
                "SOS_DEVICE_COMMAND_NATIVE_DISPATCH owner=androidService " +
                    "target=$target method=$nativeMethod opcode=${formatOpcode(opcode!!)} " +
                    "characteristic=${characteristic.uuid}",
            )
            Log.i(
                logTag,
                "SOS_DEVICE_COMMAND_GATT_WRITE_BEGIN owner=androidService " +
                    "target=$target characteristic=${characteristic.uuid} " +
                    "byteLength=${command.payload.size} writeType=${writeTypeLabel(writeType)}",
            )
        }
        val timeout = Runnable { handleCommandWriteTimeout(gatt, pending) }
        pending.timeoutRunnable = timeout
        mainHandler.postDelayed(timeout, commandWriteTimeoutMs)
        val submitStatus =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(
                    characteristic,
                    command.payload,
                    writeType,
                )
            } else {
                @Suppress("DEPRECATION")
                run {
                    characteristic.writeType = writeType
                    characteristic.value = command.payload
                    if (gatt.writeCharacteristic(characteristic)) {
                        BluetoothGatt.GATT_SUCCESS
                    } else {
                        nativeWriteSubmitRejected
                    }
                }
            }
        if (submitStatus == BluetoothStatusCodes.SUCCESS && opcode in sosCommandOpcodes) {
            Log.i(
                logTag,
                "SOS_DEVICE_COMMAND_WRITE_SUBMITTED owner=androidService " +
                    "target=$target " +
                    "characteristic=${characteristic.uuid} " +
                    "opcode=${formatOpcode(opcode!!)} androidStatus=$submitStatus",
            )
        }
        if (submitStatus != BluetoothStatusCodes.SUCCESS) {
            mainHandler.removeCallbacks(timeout)
            synchronized(commandLock) {
                if (pendingCommandResult === pending) {
                    pendingCommandResult = null
                }
            }
            val error =
                "Android native BLE owner rejected the ${command.label} write request with status $submitStatus."
            runtimeStore.recordCommandError(error)
            recordGattWriteResult(
                command = command,
                characteristic = characteristic,
                writeType = writeType,
                success = false,
                status = submitStatus.toString(),
            )
            Log.w(
                logTag,
                "[SDK_BLE_COMMAND] action=rejected label=${command.label} status=$submitStatus",
            )
            completePendingCommand(
                pending,
                commandResult(
                    success = false,
                    route = command.route,
                    result = null,
                    error = error,
                ),
            )
            invalidateCommandPathAndReconnect(gatt, "write_submit_rejected")
            return
        }
        if (opcode == 0x04) {
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
        // Method-channel success is completed only from onCharacteristicWrite.
    }

    @SuppressLint("MissingPermission")
    private fun handleCommandWriteTimeout(
        gatt: BluetoothGatt,
        pending: PendingCommandResult,
    ) {
        val ownsPending = synchronized(commandLock) {
            if (pendingCommandResult === pending) {
                pendingCommandResult = null
                true
            } else {
                false
            }
        }
        if (!ownsPending) {
            return
        }
        val command = pending.command
        val error =
            "${command.label} native write timed out before Android reported a GATT result."
        runtimeStore.recordCommandError(error)
        val characteristic =
            if (pending.characteristicUuid == cmdWriteUuid) {
                cmdWriteCharacteristic
            } else {
                inetWriteCharacteristic
            }
        recordGattWriteResult(
            command = command,
            characteristic = characteristic,
            characteristicUuid = pending.characteristicUuid,
            writeType = pending.writeType,
            success = false,
            status = "timeout",
        )
        completePendingCommand(
            pending,
            commandResult(
                success = false,
                route = command.route,
                result = null,
                error = error,
            ),
        )
        clearPendingCommandWrites()
        if (bluetoothGatt === gatt) {
            commandQueueHealthy = false
            runtimeStore.markServiceBleDisconnected()
            clearCharacteristicRefs()
            bluetoothGatt = null
            publishNativeCommandReadiness(
                reason = "command_write_timeout",
                force = true,
            )
            gatt.disconnect()
            gatt.close()
            ProtectionRuntimeBridge.recordBleEvent(
                context = context,
                type = "deviceDisconnected",
                reason = "command_write_timeout",
            )
            scheduleReconnect("command_write_timeout")
        }
    }

    private fun completePendingCommand(
        pending: PendingCommandResult,
        result: Map<String, Any?>,
    ) {
        if (!pending.claimCompletion()) {
            return
        }
        mainHandler.post {
            pending.command.completion(result)
        }
    }

    private fun recordGattWriteResult(
        command: QueuedCommand,
        characteristic: BluetoothGattCharacteristic?,
        characteristicUuid: UUID? = characteristic?.uuid,
        writeType: Int?,
        success: Boolean,
        status: String,
    ) {
        val opcode = command.payload.getOrNull(0)?.toInt()?.and(0xFF)
        if (opcode !in sosCommandOpcodes) {
            return
        }
        val target = redactDeviceTarget(targetDeviceId)
        val message =
            "SOS_DEVICE_COMMAND_GATT_WRITE_RESULT owner=androidService " +
                "target=$target characteristic=${characteristicUuid ?: "none"} " +
                "byteLength=${command.payload.size} writeType=${writeTypeLabel(writeType)} " +
                "success=$success androidStatus=$status"
        if (success) {
            Log.i(logTag, message)
        } else {
            Log.w(logTag, message)
        }
    }

    private fun writeTypeLabel(writeType: Int?): String = when (writeType) {
        BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT -> "with_response"
        BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE -> "without_response"
        BluetoothGattCharacteristic.WRITE_TYPE_SIGNED -> "signed"
        else -> "none"
    }

    private fun formatOpcode(opcode: Int): String =
        "0x${opcode.toString(16).padStart(2, '0')}"

    private fun safePacketType(
        payload: List<Int>,
        characteristic: BluetoothGattCharacteristic,
    ): String = ProtectionBleRawPacketType.classify(
        payload = payload,
        isSosCharacteristic = characteristic.uuid == sosNotifyUuid,
    )

    private fun exactConnectedDeviceIdentityReady(gatt: BluetoothGatt?): Boolean {
        val actual = gatt?.device?.address?.trim()
        val expected = runtimeStore.currentBleHardwareId()?.trim()
            ?.takeIf { it.isNotBlank() }
            ?: targetDeviceId?.trim()?.takeIf { it.isNotBlank() }
        return actual != null &&
            expected != null &&
            actual.equals(expected, ignoreCase = true)
    }

    private fun publishNativeCommandReadiness(
        reason: String,
        force: Boolean = false,
    ) {
        val gatt = bluetoothGatt
        val readiness = ProtectionNativeCommandReadiness(
            owner = runtimeActive && !isStopping,
            gattConnected = gatt != null &&
                runtimeStore.snapshot()["serviceBleConnected"] == true,
            serviceReady = eixamServiceReady,
            cmdEa04Ready = cmdWriteCharacteristic != null,
            identityReady = exactConnectedDeviceIdentityReady(gatt),
            queueHealthy = commandQueueHealthy,
        )
        Log.i(
            logTag,
            "SOS_NATIVE_SESSION_DISCOVERY " +
                "gattSessionGeneration=$gattSessionGeneration " +
                "nativeGattConnected=${readiness.gattConnected} " +
                "serviceReady=${readiness.serviceReady} " +
                "ea04Ready=${readiness.cmdEa04Ready} " +
                "identityReady=${readiness.identityReady} " +
                "queueHealthy=${readiness.queueHealthy} reason=$reason",
        )
        logNativeCommandPredicateTransitions(
            previous = lastPublishedCommandReadiness,
            next = readiness,
            reason = reason,
        )
        lastPublishedCommandReadiness = readiness
        val previous = runtimeStore.recordNativeCommandReadiness(readiness)
        Log.i(
            logTag,
            "SOS_NATIVE_COMMAND_READINESS_INPUT " +
                "nativeOwner=${readiness.owner} nativeGattConnected=${readiness.gattConnected} " +
                "serviceDiscovered=${readiness.serviceReady} ea04Present=${readiness.cmdEa04Ready} " +
                "exactIdentityMatch=${readiness.identityReady} queueHealthy=${readiness.queueHealthy} " +
                "nativeCommandReady=${readiness.ready} " +
                "falsePredicate=${readiness.falsePredicate ?: "none"} reason=$reason",
        )
        if (force || previous != readiness.ready) {
            Log.i(
                logTag,
                "SOS_NATIVE_COMMAND_READINESS_CHANGED " +
                    "previous=$previous next=${readiness.ready} reason=$reason",
            )
            ProtectionRuntimeBridge.recordNativeCommandReadinessEvent(
                context = context,
                previous = previous,
                readiness = readiness,
                sessionGeneration = gattSessionGeneration,
                reason = reason,
            )
        }
        if (readiness.ready && !previous) {
            // Reconnect: no blind stop; the gap clock restarts (frame path decides).
            onSosStaleGuardReconnected(reason)
        }
    }

    private fun logNativeCommandPredicateTransitions(
        previous: ProtectionNativeCommandReadiness?,
        next: ProtectionNativeCommandReadiness,
        reason: String,
    ) {
        val predicates = listOf(
            "nativeOwner" to (previous?.owner to next.owner),
            "nativeGattConnected" to (previous?.gattConnected to next.gattConnected),
            "serviceDiscovered" to (previous?.serviceReady to next.serviceReady),
            "ea04Present" to (previous?.cmdEa04Ready to next.cmdEa04Ready),
            "exactIdentityMatch" to (previous?.identityReady to next.identityReady),
            "queueHealthy" to (previous?.queueHealthy to next.queueHealthy),
            "nativeCommandReady" to (previous?.ready to next.ready),
        )
        predicates.forEach { (predicate, transition) ->
            if (transition.first == null || transition.first != transition.second) {
                Log.i(
                    logTag,
                    "SOS_NATIVE_COMMAND_PREDICATE_TRANSITION " +
                        "predicate=$predicate previous=${transition.first ?: "unknown"} " +
                        "next=${transition.second} reason=$reason",
                )
            }
        }
    }

    private fun redactDeviceTarget(deviceId: String?): String {
        val normalized = deviceId?.trim()?.uppercase(Locale.US)
        if (normalized.isNullOrEmpty()) {
            return "none"
        }
        if (macAddressPattern.matches(normalized)) {
            val octets = normalized.split(':')
            return "**:**:**:**:${octets[4]}:${octets[5]}"
        }
        return if (normalized.length <= 4) {
            "***"
        } else {
            "***${normalized.takeLast(4)}"
        }
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
        val existingGatt = bluetoothGatt != null
        val connected = runtimeStore.snapshot()["serviceBleConnected"] == true
        closeCurrentGattSession("replace_for_$reason")
        gattSessionGeneration += 1
        Log.i(
            logTag,
            "SOS_NATIVE_SESSION_PREPARATION_START " +
                "sessionGeneration=$gattSessionGeneration " +
                "existingGatt=$existingGatt connected=$connected reason=$reason",
        )
        connectionInFlight = true
        connectedBleNodeId = null
        bindDeviceIdentity(deviceId, runtimeStore.currentBackendHardwareId())
        clearCharacteristicRefs()
        commandQueueHealthy = true
        publishNativeCommandReadiness(reason = reason, force = true)
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
    private fun closeCurrentGattSession(reason: String) {
        serviceDiscoveryTimeoutRunnable?.let(mainHandler::removeCallbacks)
        serviceDiscoveryTimeoutRunnable = null
        val current = bluetoothGatt ?: return
        bluetoothGatt = null
        try {
            current.disconnect()
        } catch (_: Exception) {
        }
        current.close()
        runtimeStore.markServiceBleDisconnected()
        Log.i(
            logTag,
            "SOS_NATIVE_SESSION_CLOSED " +
                "gattSessionGeneration=$gattSessionGeneration reason=$reason",
        )
    }

    private fun isCurrentGattSession(gatt: BluetoothGatt, callback: String): Boolean {
        if (gatt === bluetoothGatt) {
            return true
        }
        Log.w(
            logTag,
            "SOS_NATIVE_SESSION_STALE_CALLBACK " +
                "gattSessionGeneration=$gattSessionGeneration callback=$callback",
        )
        try {
            gatt.close()
        } catch (_: Exception) {
        }
        return false
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
    private fun refreshGattCache(gatt: BluetoothGatt): Boolean {
        return try {
            val refresh = gatt.javaClass.getMethod("refresh")
            val cleared = refresh.invoke(gatt) as? Boolean ?: false
            if (cleared) {
                ProtectionRuntimeBridge.recordBleEvent(
                    context = context,
                    type = "gattCacheCleared",
                    reason = "android_stale_handle_guard",
                )
            }
            cleared
        } catch (error: Exception) {
            Log.w(logTag, "GATT cache refresh unavailable: ${error.message}")
            false
        }
    }

    @SuppressLint("MissingPermission")
    private fun discoverServices(gatt: BluetoothGatt) {
        if (!isCurrentGattSession(gatt, "discoverServices")) {
            return
        }
        // Provision/unprovision reboot adds or removes Meshtastic Phone BLE.
        // Android's per-MAC cache can then point SOS CCCD at a read-only
        // handle. A successful refresh invalidates this live session, so
        // discovery must run on a newly created generation.
        val skipCacheRefresh = skipGattCacheRefreshForNextSession
        skipGattCacheRefreshForNextSession = false
        if (!skipCacheRefresh && refreshGattCache(gatt)) {
            skipGattCacheRefreshForNextSession = true
            connectionInFlight = false
            clearCharacteristicRefs()
            closeCurrentGattSession("gatt_cache_cleared_recreate")
            publishNativeCommandReadiness(
                reason = "gatt_cache_cleared_recreate",
                force = true,
            )
            mainHandler.post {
                if (!isStopping && runtimeActive && bluetoothGatt == null) {
                    connect(reason = "gatt_cache_cleared_recreate")
                }
            }
            return
        }
        Log.i(
            logTag,
            "SOS_NATIVE_SESSION_DISCOVERY_BEGIN " +
                "sessionGeneration=$gattSessionGeneration",
        )
        val discovered = gatt.discoverServices()
        if (!discovered) {
            logNativeSessionDiscoveryResult(
                serviceReady = false,
                ea04Ready = false,
                reason = "discover_services_failed",
            )
            failCurrentNativeSession(gatt, "discover_services_failed")
            return
        }
        scheduleServiceDiscoveryTimeout(gatt, gattSessionGeneration)
    }

    private fun scheduleServiceDiscoveryTimeout(
        gatt: BluetoothGatt,
        sessionGeneration: Long,
    ) {
        serviceDiscoveryTimeoutRunnable?.let(mainHandler::removeCallbacks)
        serviceDiscoveryTimeoutRunnable = Runnable {
            val failure = evaluateProtectionNativePreparationFailure(
                gattConnected = runtimeStore.snapshot()["serviceBleConnected"] == true,
                discoveryCompleted = false,
                serviceReady = eixamServiceReady,
                ea04Ready = cmdWriteCharacteristic != null,
                identityReady = exactConnectedDeviceIdentityReady(gatt),
                queueHealthy = commandQueueHealthy,
                discoveryTimedOut = true,
            )
            if (gatt === bluetoothGatt &&
                sessionGeneration == gattSessionGeneration &&
                failure != null
            ) {
                logNativeSessionDiscoveryResult(
                    serviceReady = eixamServiceReady,
                    ea04Ready = cmdWriteCharacteristic != null,
                    reason = failure.wireReason,
                )
                failCurrentNativeSession(gatt, failure.wireReason)
            }
        }.also {
            mainHandler.postDelayed(it, serviceDiscoveryTimeoutMs)
        }
    }

    private fun logNativeSessionDiscoveryResult(
        serviceReady: Boolean,
        ea04Ready: Boolean,
        reason: String,
    ) {
        Log.i(
            logTag,
            "SOS_NATIVE_SESSION_DISCOVERY_RESULT " +
                "sessionGeneration=$gattSessionGeneration " +
                "serviceReady=$serviceReady ea04Ready=$ea04Ready reason=$reason",
        )
    }

    @SuppressLint("MissingPermission")
    private fun failCurrentNativeSession(gatt: BluetoothGatt, reason: String) {
        if (!isCurrentGattSession(gatt, "failure_$reason")) {
            return
        }
        serviceDiscoveryTimeoutRunnable?.let(mainHandler::removeCallbacks)
        serviceDiscoveryTimeoutRunnable = null
        connectionInFlight = false
        commandQueueHealthy = false
        clearCharacteristicRefs()
        runtimeStore.markRuntimeFailure("E_NATIVE_BLE_PREPARATION_FAILED:$reason")
        closeCurrentGattSession(reason)
        publishNativeCommandReadiness(reason = reason, force = true)
        ProtectionRuntimeBridge.recordPlatformEvent(
            context = context,
            type = "runtimeError",
            reason = "native_preparation_failed:$reason",
        )
        ProtectionRuntimeBridge.recordBleEvent(
            context = context,
            type = "reconnectFailed",
            reason = reason,
        )
        scheduleReconnect(reason)
    }

    @SuppressLint("MissingPermission")
    private fun configureSubscriptions(gatt: BluetoothGatt) {
        if (!isCurrentGattSession(gatt, "configureSubscriptions")) {
            return
        }
        val discoveredServicesSummary = gatt.services.joinToString(separator = " | ") { service ->
            val characteristics = service.characteristics.joinToString(separator = ",") {
                it.uuid.toString().lowercase(Locale.US)
            }
            "${service.uuid.toString().lowercase(Locale.US)}[$characteristics]"
        }
        runtimeStore.recordDiscoveredServicesSummary(discoveredServicesSummary)
        val service = gatt.getService(serviceUuid)
        if (service == null) {
            eixamServiceReady = false
            val failure = evaluateProtectionNativePreparationFailure(
                gattConnected = true,
                discoveryCompleted = true,
                serviceReady = false,
                ea04Ready = false,
                identityReady = exactConnectedDeviceIdentityReady(gatt),
                queueHealthy = commandQueueHealthy,
                discoveryTimedOut = false,
            ) ?: ProtectionNativePreparationFailure.serviceAbsent
            logNativeSessionDiscoveryResult(
                serviceReady = false,
                ea04Ready = false,
                reason = failure.wireReason,
            )
            publishNativeCommandReadiness(
                reason = failure.wireReason,
                force = true,
            )
            val failureReason =
                "Expected BLE service ${serviceUuid.toString().lowercase(Locale.US)} was not found. Discovered services: ${if (discoveredServicesSummary.isBlank()) "none" else discoveredServicesSummary}"
            runtimeStore.markRuntimeFailure(failureReason)
            ProtectionRuntimeBridge.recordPlatformEvent(
                context = context,
                type = "runtimeError",
                reason = failureReason,
            )
            failCurrentNativeSession(gatt, failure.wireReason)
            return
        }

        eixamServiceReady = true
        telNotifyCharacteristic = service.getCharacteristic(telNotifyUuid)
        sosNotifyCharacteristic = service.getCharacteristic(sosNotifyUuid)
        inetWriteCharacteristic = service.getCharacteristic(inetWriteUuid)
        cmdWriteCharacteristic = service.getCharacteristic(cmdWriteUuid)
        logNativeSessionDiscoveryResult(
            serviceReady = true,
            ea04Ready = cmdWriteCharacteristic != null,
            reason = "services_discovered",
        )

        if (
            telNotifyCharacteristic == null ||
            sosNotifyCharacteristic == null ||
            inetWriteCharacteristic == null ||
            cmdWriteCharacteristic == null
        ) {
            val typedFailureReason = if (cmdWriteCharacteristic == null) {
                ProtectionNativePreparationFailure.ea04Absent.wireReason
            } else {
                "required_characteristics_missing"
            }
            commandQueueHealthy = false
            publishNativeCommandReadiness(
                reason = typedFailureReason,
                force = true,
            )
            val missingCharacteristics = buildList<String> {
                if (telNotifyCharacteristic == null) add(telNotifyUuid.toString().lowercase(Locale.US))
                if (sosNotifyCharacteristic == null) add(sosNotifyUuid.toString().lowercase(Locale.US))
                if (inetWriteCharacteristic == null) add(inetWriteUuid.toString().lowercase(Locale.US))
                if (cmdWriteCharacteristic == null) add(cmdWriteUuid.toString().lowercase(Locale.US))
            }
            val discoveredCharacteristics = service.characteristics.joinToString(separator = ",") {
                it.uuid.toString().lowercase(Locale.US)
            }
            val humanFailureReason =
                "Required EIXAM protection characteristics are missing. Expected ${missingCharacteristics.joinToString()} but discovered $discoveredCharacteristics."
            runtimeStore.markRuntimeFailure(humanFailureReason)
            ProtectionRuntimeBridge.recordPlatformEvent(
                context = context,
                type = "runtimeError",
                reason = humanFailureReason,
            )
            failCurrentNativeSession(gatt, typedFailureReason)
            return
        }

        commandQueueHealthy = true
        val preparationFailure = evaluateProtectionNativePreparationFailure(
            gattConnected = true,
            discoveryCompleted = true,
            serviceReady = eixamServiceReady,
            ea04Ready = cmdWriteCharacteristic != null,
            identityReady = exactConnectedDeviceIdentityReady(gatt),
            queueHealthy = commandQueueHealthy,
            discoveryTimedOut = false,
        )
        if (preparationFailure != null) {
            publishNativeCommandReadiness(
                reason = preparationFailure.wireReason,
                force = true,
            )
            failCurrentNativeSession(gatt, preparationFailure.wireReason)
            return
        }
        publishNativeCommandReadiness(
            reason = "eixam_service_and_ea04_discovered",
            force = true,
        )

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
        if (!isCurrentGattSession(gatt, "enableCharacteristicNotifications")) {
            return
        }
        val notificationEnabled = gatt.setCharacteristicNotification(characteristic, true)
        if (!notificationEnabled) {
            runtimeStore.markRuntimeFailure("Could not enable notifications for ${characteristic.uuid}.")
            ProtectionRuntimeBridge.recordPlatformEvent(
                context = context,
                type = "runtimeError",
                reason = "set_notify_failed",
            )
            failCurrentNativeSession(gatt, "set_notify_failed")
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
            failCurrentNativeSession(gatt, "cccd_missing")
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
            failCurrentNativeSession(gatt, "cccd_write_failed")
        }
    }

    private fun clearCharacteristicRefs() {
        eixamServiceReady = false
        telNotifyCharacteristic = null
        sosNotifyCharacteristic = null
        inetWriteCharacteristic = null
        cmdWriteCharacteristic = null
        clearPendingCommandWrites()
    }

    @SuppressLint("MissingPermission")
    private fun invalidateCommandPathAndReconnect(
        gatt: BluetoothGatt,
        reason: String,
    ) {
        failCurrentNativeSession(gatt, reason)
    }

    private fun clearPendingCommandWrites() {
        val commands = mutableListOf<QueuedCommand>()
        val pending = synchronized(commandLock) {
            val active = pendingCommandResult
            pendingCommandResult = null
            while (pendingCommandQueue.isNotEmpty()) {
                commands.add(pendingCommandQueue.removeFirst())
            }
            active
        }
        val error = "Native BLE command cancelled because the GATT session changed."
        pending?.timeoutRunnable?.let(mainHandler::removeCallbacks)
        pending?.let {
            completePendingCommand(
                it,
                commandResult(
                    success = false,
                    route = it.command.route,
                    result = null,
                    error = error,
                ),
            )
        }
        commands.forEach { command ->
            command.completion(
                commandResult(
                    success = false,
                    route = command.route,
                    result = null,
                    error = error,
                ),
            )
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
                val error =
                    "${next.label} queued native write dropped because the BLE session changed."
                runtimeStore.recordCommandError(error)
                Log.w(
                    logTag,
                    "[SDK_BLE_COMMAND] action=dropped label=${next.label} reason=session_changed",
                )
                next.completion(
                    commandResult(
                        success = false,
                        route = next.route,
                        result = null,
                        error = error,
                    ),
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
        val receiveSequence = ++notificationReceiveSequence
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
        val packetType = safePacketType(payload, characteristic)
        val receiveCorrelation = "native-$receiveSequence"
        val connectedDeviceMarker = redactDeviceTarget(activeBleHardwareId ?: targetDeviceId)
        Log.i(
            logTag,
            "EIXAM_NATIVE_NOTIFICATION_RX producer=native_bridge owner=native_protection " +
                "characteristic=${characteristic.uuid} byteLength=${payload.size} " +
                "packetType=$packetType " +
                "firstOpcode=${payload.firstOrNull()?.let(::formatOpcode) ?: "none"} " +
                "receiveSequence=$receiveSequence correlation=$receiveCorrelation " +
                "connectedDevice=$connectedDeviceMarker",
        )
        ProtectionRuntimeBridge.recordRawBleNotification(
            payloadHex = payloadHex(payload),
            source = sourceLabel,
            characteristicUuid = characteristic.uuid.toString(),
            byteLength = payload.size,
            packetType = packetType,
            firstOpcode = payload.firstOrNull()?.let(::formatOpcode) ?: "none",
            receiveSequence = receiveSequence,
            receiveCorrelation = receiveCorrelation,
            connectedDeviceMarker = connectedDeviceMarker,
        )
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
            // 0xD0 chunks only. Nearby 0xD8/0xDA/0xDB must not be rejected by
            // first byte: SOS node id is little-endian at offset 0, so a low
            // byte of 0xD8/0xDA/0xDB is a real SOS. Non-fragment nearby misses
            // the 7/12-byte SOS parse (0xDA status is 6 B; 0xD8 text is ≥ 22 B)
            // and is emitted below.
            if (TelAggregateFragment.tryParse(payload) != null) {
                ProtectionRuntimeBridge.emitTelNotify(
                    context = context,
                    payload = payload,
                    source = "tel",
                )
                return
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
                    logSosTrace(
                        "native_lifecycle_gate classification=ownDeviceSos " +
                            "action=observe_local_lifecycle observeSosLifecycle_called=true",
                    )
                    // Classified first: frames of an SOS the SDK closed never reach Dart (F17b H4).
                    if (observeSosLifecycle(payload)) {
                        ProtectionRuntimeBridge.recordBleEvent(
                            context = context,
                            type = "telDerivedSosReceived",
                            reason = payloadHex(payload),
                        )
                    }
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
            ProtectionRuntimeBridge.emitTelNotify(
                context = context,
                payload = payload,
                source = "tel",
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
            // Classified first: frames of an SOS the SDK closed never reach Dart (F17b H4).
            val passesToDart = observeSosLifecycle(payload)
            if (passesToDart) {
                ProtectionRuntimeBridge.recordBleEvent(
                    context = context,
                    type = nativeRoute.diagnosticEventType ?: "ownDeviceSosLifecycleObserved",
                    reason = "own:${ProtectionBleSosRelaySource.sos.name}:${payloadHex(payload)}",
                )
            }
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
            logSosTrace(
                "native_lifecycle_gate classification=ownDeviceSos " +
                    "action=observe_local_lifecycle observeSosLifecycle_called=true",
            )
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
        val relayHardwareId = activeBleHardwareId?.trim()?.takeIf { it.isNotBlank() }
        val rawPayloadHex = payloadHex(classification.rawPayload)
        val stored = runtimeStore.recordPendingExternalRelayCancel(
            originatorNodeId = classification.originatorNodeId,
            relayNodeId = classification.relayNodeId,
            relayHardwareId = relayHardwareId,
            rawPayloadHex = rawPayloadHex,
            source = "remote_lora_relay",
        )
        logSosTrace(
            if (stored) {
                "EXTERNAL_SOS pending_cancel_stored originatorNodeId=${classification.originatorNodeId} " +
                    "relayNodeId=${classification.relayNodeId} relayHardwareId=${relayHardwareId ?: "none"}"
            } else {
                "EXTERNAL_SOS pending_cancel_dedupe_skip originatorNodeId=${classification.originatorNodeId} " +
                    "relayNodeId=${classification.relayNodeId} relayHardwareId=${relayHardwareId ?: "none"}"
            },
        )
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
                "lat=none lon=none alt=none payloadHex=$rawPayloadHex",
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
                "remote:${classification.source.name}:${classification.relayNodeId}:$rawPayloadHex",
            )
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
        ProtectionBleSosIdentityClassifier.boundSosBody(payload)?.let { return readU32OrNull(it, 0) }
        if (
            payload.size == 6 &&
            (payload[0] == 0xE1 || payload[0] == 0xE2 || payload[0] == 0xE3)
        ) {
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
        val latEnc =
            ((payload[offset] and 0xFF) shl 12) or
                ((payload[offset + 1] and 0xFF) shl 4) or
                (((payload[offset + 2] and 0xFF) shr 4) and 0x0F)
        val lonEnc =
            (((payload[offset + 2] and 0xFF) and 0x0F) shl 17) or
                ((payload[offset + 3] and 0xFF) shl 9) or
                ((payload[offset + 4] and 0xFF) shl 1) or
                ((payload[offset + 5] and 0xFF) and 0x01)
        val altEnc = ((payload[offset + 5] and 0xFF) shr 1) and 0x7F
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

    /**
     * Applies one own-device SOS frame. Returns whether the frame may reach Dart
     * (`ownDeviceSosLifecycleObserved` / `telDerivedSosReceived`): frames of an
     * SOS the SDK already closed, copies and frames still being classified never
     * do (F17b H4). The lifecycle, the activation timer and the stale guard are
     * mutated only under [sosLifecycleLock] (M3); TAG writes and notifications
     * run after it.
     */
    private fun observeSosLifecycle(payload: List<Int>): Boolean {
        if (payload.isEmpty()) {
            return true
        }
        val effects = SosStaleEffects()
        val passes = synchronized(sosLifecycleLock) { observeSosLifecycleLocked(payload, effects) }
        runSosStaleEffects(effects)
        return passes
    }

    private fun observeSosLifecycleLocked(payload: List<Int>, effects: SosStaleEffects): Boolean {
        when (payload.size) {
            4, 6 -> {
                val opcode = payload[0] and 0xFF
                val subcode = payload[1] and 0xFF
                val closed = (opcode == 0xE1 && (subcode == 0x01 || subcode == 0x02)) ||
                    (opcode == 0xE2 && (subcode == 0x01 || subcode == 0x02 || subcode == 0x03)) ||
                    (opcode == 0xE3 && (subcode == 0x01 || subcode == 0x02 || subcode == 0x03))
                if (closed) {
                    runtimeStore.recordOwnSosCloseObserved(System.currentTimeMillis())
                    // The TAG confirmed the stop (or closed the SOS itself): the guard
                    // ends. A cycle the SDK already closed is idle, so no backend cancel.
                    disarmSosStaleGuardLocked("tag_close_0x${"%02X".format(opcode)}")
                    setSosObservedCycleLocked(null)
                }
                if (closed && pendingSosLifecycleState != ProtectionSosLifecycleState.idle) {
                    val lifecycleSnapshot = runtimeStore.snapshot()
                    val closedCycleKey = lifecycleSnapshot["preSosCycleKey"] as? String
                    val closeOutcome =
                        ProtectionSosLifecycleLogic.onClosePacket(
                            currentState = pendingSosLifecycleState,
                            backendTerminal = opcode == 0xE3,
                        )
                    pendingSosLifecycleState = closeOutcome.nextState
                    cancelSosActivationTimeout()
                    runtimeStore.recordPreSosLifecycle(
                        state = pendingSosLifecycleState.name,
                        cycleKey = closedCycleKey,
                        owner = "device",
                        startedAt = null,
                        expectedActivationAt = null,
                        originatorNodeId = readPacketOriginatorNodeId(payload),
                        packetId = null,
                    )
                    ProtectionForegroundService.showResolvedSosNotification(context)
                    if (closeOutcome.shouldCancelBackend) {
                        backendHandoff.queueCancel(
                            reason = "device_cycle_closed",
                            lifecycleId = closedCycleKey,
                        )
                    }
                    runtimeStore.clearPreSosLifecycle()
                    pendingSosLifecycleState = ProtectionSosLifecycleState.idle
                }
                return true
            }

            5, 7, 10, 12 -> {
                val now = System.currentTimeMillis()
                runtimeStore.recordOwnSosFrameObserved(now)
                val outcome = ProtectionSosStaleGuard.onFrame(
                    sosStaleGuard,
                    readPacketOriginatorNodeId(payload),
                    now,
                )
                applySosStaleOutcomeLocked(outcome, effects)
                if (!outcome.passesToLifecycle) {
                    // The closed SOS, a copy, or still deciding: never a new SOS.
                    return false
                }
                val observedAt =
                    if (outcome.action == ProtectionSosStaleAction.newSos) outcome.startedAt ?: now else now
                val parsedCycle = parsePreSosCycle(payload)
                val nextState = ProtectionSosLifecycleLogic.onMeshPacket(pendingSosLifecycleState)
                if (nextState == ProtectionSosLifecycleState.preConfirmSeen &&
                    pendingSosLifecycleState != ProtectionSosLifecycleState.preConfirmSeen
                ) {
                    pendingSosLifecycleState = nextState
                    val startedAt = observedAt - observedPreSosSkewMs
                    val expectedActivationAt = startedAt + sosActivationDelayMs
                    runtimeStore.recordPreSosLifecycle(
                        state = pendingSosLifecycleState.name,
                        cycleKey = parsedCycle?.cycleKey,
                        owner = "device",
                        startedAt = startedAt,
                        expectedActivationAt = expectedActivationAt,
                        originatorNodeId = parsedCycle?.originatorNodeId,
                        packetId = parsedCycle?.packetId,
                    )
                    ProtectionForegroundService.showPreConfirmNotification(context)
                    scheduleSosActivationTimeout(expectedActivationAt = expectedActivationAt)
                }
                return true
            }
        }
        return true
    }

    /**
     * F17b: the SDK ended an SOS (Dart `closeNativeSosCycle`). A handed-over
     * cycle (createPending, create claimed by the SDK) always closes so
     * rehydrate never re-creates it (M5); a running countdown or an unclaimed
     * create is never touched. With a cancel/resolve terminal the stale guard
     * arms and, when the TAG is reachable and was still sending the SOS, this
     * native GATT session writes the SDK's own terminal command at once. Never
     * depends on Dart's connection state.
     */
    fun closeNativeSosCycle(terminalWire: String?, nodeId: Int?, force: Boolean) {
        mainHandler.post {
            val now = System.currentTimeMillis()
            val stopNow = synchronized(sosLifecycleLock) {
                if (force) {
                    // Session change: nothing of the previous account survives.
                    cancelSosActivationTimeout()
                    pendingSosLifecycleState = ProtectionSosLifecycleState.idle
                    runtimeStore.clearPreSosLifecycle()
                    disarmSosStaleGuardLocked("session_changed")
                    setSosObservedCycleLocked(null)
                    return@synchronized false
                }
                val terminal = ProtectionSosStaleTerminal.fromWire(terminalWire)
                val snapshot = runtimeStore.snapshot()
                val storedState = (snapshot["preSosLifecycleState"] as? String)
                    ?.let { name -> ProtectionSosLifecycleState.entries.firstOrNull { it.name == name } }
                val lifecycleState =
                    if (pendingSosLifecycleState != ProtectionSosLifecycleState.idle) {
                        pendingSosLifecycleState
                    } else {
                        storedState ?: ProtectionSosLifecycleState.idle
                    }
                val storedNodeId = snapshot["preSosOriginatorNodeId"] as? Int
                val unclaimed = runtimeStore.hasPendingNativeSosCreate()
                // F17c-cdc: only the cancel of this TAG's countdown ends it.
                val countdownStartedAt = (snapshot["preSosStartedAt"] as? Long)?.takeIf {
                    nodeId == null || storedNodeId == null || nodeId == storedNodeId
                }
                val nextState =
                    if (ProtectionSosStaleGuard.cancelsRunningCountdown(
                            terminal, lifecycleState, unclaimed, countdownStartedAt, now,
                        )
                    ) {
                        ProtectionSosLifecycleState.idle
                    } else {
                        ProtectionSosLifecycleLogic.onSdkClose(lifecycleState, unclaimed)
                    }
                if (nextState != lifecycleState) {
                    cancelSosActivationTimeout()
                    pendingSosLifecycleState = nextState
                    runtimeStore.clearPreSosLifecycle()
                    Log.i(
                        logTag,
                        "NATIVE_SOS_CYCLE_CLOSED_BY_SDK terminal=${terminalWire ?: "none"} " +
                            "lifecycle=${lifecycleState.name}",
                    )
                }
                val observed = sosObservedCycle
                val dartSeen = ProtectionSosStaleGuard.observedHandedOver(observed, now)
                if (terminal == null ||
                    !ProtectionSosStaleGuard.shouldArm(terminal, lifecycleState, unclaimed, observed, now)
                ) {
                    Log.i(
                        logTag,
                        "NATIVE_SOS_STALE_GUARD_NOT_ARMED terminal=${terminalWire ?: "none"} " +
                            "lifecycle=${lifecycleState.name} unclaimedCreate=$unclaimed " +
                            "dartSeen=$dartSeen",
                    )
                    return@synchronized false
                }
                val connected = lastPublishedCommandReadiness?.ready == true
                val armed = ProtectionSosStaleGuard.arm(
                    terminal = terminal,
                    nodeId = nodeId ?: storedNodeId ?: observed?.nodeId ?: connectedBleNodeId,
                    now = now,
                    connected = connected,
                )
                cancelSosStaleDecide()
                sosStaleGuard = armed
                runtimeStore.saveSosStaleGuard(armed)
                setSosObservedCycleLocked(null)
                Log.i(
                    logTag,
                    "NATIVE_SOS_STALE_GUARD_ARMED terminal=${terminal.wire} " +
                        "lifecycle=${lifecycleState.name} connected=$connected dartSeen=$dartSeen",
                )
                ProtectionSosStaleGuard.shouldSendStopOnArm(
                    lastSosFrameAt = runtimeStore.lastOwnSosFrameAt(),
                    connected = connected,
                    now = now,
                )
            }
            if (stopNow) {
                sendSosStaleStop(reason = "sdk_close")
            }
        }
    }

    /**
     * F17c: one own-TAG SOS frame Dart received through its own BLE link
     * (flutter_blue_plus). Native is the single classifier for every own-TAG
     * frame whichever path received it: the same guard, copy collapse (< 300 ms,
     * also across paths) and burst rule. Works with or without Protection
     * armed (pure persistence). Dart acts only on the returned verdict.
     * [receivedAtMs]: when Dart received the frame (M-C, sanity-bounded).
     */
    fun observeForwardedOwnTagSosFrame(
        payload: List<Int>,
        receivedAtMs: Long? = null,
    ): ProtectionOwnTagSosVerdict {
        val frame = ProtectionSosForwardedFrame.parse(payload)
            ?: return ProtectionOwnTagSosVerdict.proceed
        val effects = SosStaleEffects()
        val decision = synchronized(sosLifecycleLock) {
            val now = System.currentTimeMillis()
            val decision = ProtectionSosStaleGuard.onForwardedFrame(
                sosStaleGuard,
                sosObservedCycle,
                frame,
                now,
                receivedAt = receivedAtMs,
            )
            val otherTag = decision.outcome.action == ProtectionSosStaleAction.ignored
            if (frame.close && !otherTag) {
                runtimeStore.recordOwnSosCloseObserved(now)
            } else if (!frame.close) {
                runtimeStore.recordOwnSosFrameObserved(now)
            }
            if (frame.close) {
                // Another TAG's close never ends this guard.
                if (!otherTag) disarmSosStaleGuardLocked("tag_close_dart")
            } else {
                applySosStaleOutcomeLocked(decision.outcome, effects)
            }
            setSosObservedCycleLocked(decision.observed)
            decision
        }
        runSosStaleEffects(effects)
        if (decision.verdict != ProtectionOwnTagSosVerdict.proceed) {
            Log.i(
                logTag,
                "NATIVE_SOS_STALE_DART_FRAME verdict=${decision.verdict.name} " +
                    "action=${decision.outcome.action.name}",
            )
        }
        return decision.verdict
    }

    /** F17c: the SDK opened a new SOS lifecycle: no pending decision may stop it (M3). */
    fun disarmSosStaleGuard(reason: String) {
        synchronized(sosLifecycleLock) { disarmSosStaleGuardLocked(reason) }
    }

    /**
     * F17c: Dart's own TAG link changed (native sees no link events while Dart
     * owns it). M-B: Dart notes every command-path flip, a native<->Dart owner
     * handover included, so this never resets a burst being counted nor
     * cancels its pending decision (iOS noteLinkUp semantics).
     */
    fun noteForwardedOwnTagLink(up: Boolean) {
        val now = System.currentTimeMillis()
        synchronized(sosLifecycleLock) {
            val current = sosStaleGuard ?: return
            if (up && ProtectionSosStaleGuard.isExpired(current, now)) {
                disarmSosStaleGuardLocked("cap")
                return
            }
            val next = if (up) {
                ProtectionSosStaleGuard.onForwardedLinkUp(current, now)
            } else {
                ProtectionSosStaleGuard.onForwardedLinkDropped(current)
            }
            sosStaleGuard = next
            runtimeStore.saveSosStaleGuard(next)
        }
        Log.i(logTag, "NATIVE_SOS_STALE_GUARD_DART_LINK up=$up")
    }

    private fun setSosObservedCycleLocked(observed: ProtectionSosObservedCycle?) {
        if (observed == sosObservedCycle) return
        sosObservedCycle = observed
        runtimeStore.saveSosObservedCycle(observed)
    }

    private class SosStaleEffects {
        var sendStop = false
        var showNotice = false
    }

    private fun applySosStaleOutcomeLocked(outcome: ProtectionSosStaleOutcome, effects: SosStaleEffects) {
        when (outcome.action) {
            ProtectionSosStaleAction.notArmed,
            ProtectionSosStaleAction.none,
            ProtectionSosStaleAction.ignored,
            ProtectionSosStaleAction.duplicate,
            -> Unit

            ProtectionSosStaleAction.disarmed ->
                disarmSosStaleGuardLocked(outcome.reason ?: "disarmed")

            ProtectionSosStaleAction.newSos ->
                disarmSosStaleGuardLocked(outcome.reason ?: "countdown_burst")

            ProtectionSosStaleAction.pending,
            ProtectionSosStaleAction.stale,
            -> {
                sosStaleGuard = outcome.state
                runtimeStore.saveSosStaleGuard(outcome.state)
                outcome.decideAt?.let(::scheduleSosStaleDecideLocked)
            }
        }
        if (outcome.sendStop) effects.sendStop = true
        if (outcome.showNotice) effects.showNotice = true
    }

    private fun runSosStaleEffects(effects: SosStaleEffects) {
        if (effects.sendStop) {
            sendSosStaleStop(reason = "stale_frame")
        }
        if (effects.showNotice) {
            ProtectionForegroundService.showSosStaleStoppedNotification(context)
        }
    }

    private fun scheduleSosStaleDecideLocked(decideAt: Long) {
        cancelSosStaleDecide()
        sosStaleDecideRunnable = Runnable {
            val effects = SosStaleEffects()
            synchronized(sosLifecycleLock) {
                sosStaleDecideRunnable = null
                val current = sosStaleGuard ?: return@synchronized
                applySosStaleOutcomeLocked(
                    ProtectionSosStaleGuard.onDecide(current, System.currentTimeMillis()),
                    effects,
                )
            }
            runSosStaleEffects(effects)
        }.also {
            mainHandler.postDelayed(it, (decideAt - System.currentTimeMillis()).coerceAtLeast(0L))
        }
    }

    private fun cancelSosStaleDecide() {
        sosStaleDecideRunnable?.let(mainHandler::removeCallbacks)
        sosStaleDecideRunnable = null
    }

    private fun markSosStaleGuardLinkDropped(reason: String) {
        synchronized(sosLifecycleLock) {
            val current = sosStaleGuard ?: return
            cancelSosStaleDecide()
            val next = ProtectionSosStaleGuard.onLinkDropped(current)
            sosStaleGuard = next
            runtimeStore.saveSosStaleGuard(next)
        }
        Log.i(logTag, "NATIVE_SOS_STALE_GUARD_LINK_DROPPED reason=$reason")
    }

    private fun disarmSosStaleGuardLocked(reason: String) {
        val had = sosStaleGuard != null
        cancelSosStaleDecide()
        sosStaleGuard = null
        runtimeStore.saveSosStaleGuard(null)
        if (had) {
            Log.i(logTag, "NATIVE_SOS_STALE_GUARD_DISARMED reason=$reason")
        }
    }

    /**
     * Reconnect never writes a stop by itself: a COUNTDOWN started while
     * disconnected is a genuine new SOS. A TAG still running the closed SOS is
     * stopped on its next retry frame; one silent > 90 s disarms by gap.
     */
    private fun onSosStaleGuardReconnected(reason: String) {
        val now = System.currentTimeMillis()
        synchronized(sosLifecycleLock) {
            val current = sosStaleGuard ?: return
            if (ProtectionSosStaleGuard.isExpired(current, now)) {
                disarmSosStaleGuardLocked("cap")
                return
            }
            cancelSosStaleDecide()
            val next = ProtectionSosStaleGuard.onReconnected(current, now)
            sosStaleGuard = next
            runtimeStore.saveSosStaleGuard(next)
        }
        Log.i(logTag, "NATIVE_SOS_STALE_GUARD_RECONNECTED reason=$reason")
    }

    /**
     * The SDK's own terminal command. F17c: written by this native GATT session
     * when it owns a writable link; otherwise (Dart owns the link, e.g. the app
     * in the foreground) Dart writes it on `ownTagSosStopRequired`.
     */
    private fun sendSosStaleStop(reason: String) {
        val current = synchronized(sosLifecycleLock) { sosStaleGuard } ?: return
        val terminal = current.terminal
        if (!runtimeActive || lastPublishedCommandReadiness?.ready != true) {
            requestDartSosStaleStop(terminal, reason)
            return
        }
        Log.i(
            logTag,
            "NATIVE_SOS_STALE_STOP_SENT terminal=${terminal.wire} command=${terminal.commandLabel} reason=$reason",
        )
        sendCommand(
            label = terminal.commandLabel,
            payload = terminal.stopPayload,
            forceCmdCharacteristic = true,
        ) { result ->
            val success = result["success"] == true
            Log.i(
                logTag,
                "NATIVE_SOS_STALE_STOP_RESULT terminal=${terminal.wire} success=$success",
            )
            // Only while the guard is still armed: a new SDK SOS may have
            // disarmed it while the write was queued (M3).
            if (!success && synchronized(sosLifecycleLock) { sosStaleGuard } != null) {
                requestDartSosStaleStop(terminal, "${reason}_native_write_failed")
            }
        }
    }

    private fun requestDartSosStaleStop(terminal: ProtectionSosStaleTerminal, reason: String) {
        Log.i(
            logTag,
            "NATIVE_SOS_STALE_STOP_REQUIRED_FROM_DART terminal=${terminal.wire} reason=$reason " +
                "dartListening=${ProtectionRuntimeBridge.isFlutterListening()}",
        )
        // M-A: delivered to a live listener only, never buffered and replayed
        // later (ProtectionPlatformEventBuffer.liveOnlyTypes).
        ProtectionRuntimeBridge.recordPlatformEvent(
            context = context,
            type = "ownTagSosStopRequired",
            reason = terminal.wire,
        )
    }

    private fun scheduleSosActivationTimeout(expectedActivationAt: Long = System.currentTimeMillis() + sosActivationDelayMs) {
        sosActivationRunnable?.let(mainHandler::removeCallbacks)
        val delayMs = (expectedActivationAt - System.currentTimeMillis()).coerceAtLeast(0L)
        sosActivationRunnable = Runnable { synchronized(sosLifecycleLock) {
            val nextState =
                ProtectionSosLifecycleLogic.onCountdownElapsed(pendingSosLifecycleState)
            if (nextState == ProtectionSosLifecycleState.createPending &&
                pendingSosLifecycleState == ProtectionSosLifecycleState.preConfirmSeen
            ) {
                pendingSosLifecycleState = nextState
                val snapshot = runtimeStore.snapshot()
                runtimeStore.recordPreSosLifecycle(
                    state = pendingSosLifecycleState.name,
                    cycleKey = snapshot["preSosCycleKey"] as? String,
                    owner = snapshot["preSosOwner"] as? String ?: "device",
                    startedAt = snapshot["preSosStartedAt"] as? Long,
                    expectedActivationAt = snapshot["preSosExpectedActivationAt"] as? Long,
                    originatorNodeId = snapshot["preSosOriginatorNodeId"] as? Int,
                    packetId = snapshot["preSosPacketId"] as? Int,
                )
                ProtectionForegroundService.showActiveSosNotification(context)
                backendHandoff.queueCreate("device_cycle_active_after_timeout")
            }
            sosActivationRunnable = null
        } }.also {
            mainHandler.postDelayed(it, delayMs)
        }
    }

    private fun cancelSosActivationTimeout() {
        sosActivationRunnable?.let(mainHandler::removeCallbacks)
        sosActivationRunnable = null
    }

    private fun rehydratePreSosLifecycle(reason: String) {
        val snapshot = runtimeStore.snapshot()
        val state = snapshot["preSosLifecycleState"] as? String ?: return
        val restoredState =
            ProtectionSosLifecycleState.entries.firstOrNull { it.name == state }
                ?: ProtectionSosLifecycleState.idle
        // An SDK close sets the stored cycle idle (F17b): never re-created here.
        if (ProtectionSosLifecycleLogic.shouldRequeueCreateOnRehydrate(restoredState)) {
            pendingSosLifecycleState = ProtectionSosLifecycleState.createPending
            cancelSosActivationTimeout()
            ProtectionForegroundService.showActiveSosNotification(context)
            if (!runtimeStore.hasPendingNativeSosCreate()) {
                backendHandoff.queueCreate("restored_device_cycle_active")
            } else {
                backendHandoff.flushPendingActions("restored_device_cycle_active")
            }
            ProtectionRuntimeBridge.recordPlatformEvent(
                context = context,
                type = "runtimeRecovered",
                reason = "pre_sos_active_rehydrated:$reason",
            )
            return
        }
        if (state != ProtectionSosLifecycleState.preConfirmSeen.name) {
            return
        }
        val expectedActivationAt = snapshot["preSosExpectedActivationAt"] as? Long ?: return
        pendingSosLifecycleState = ProtectionSosLifecycleState.preConfirmSeen
        if (System.currentTimeMillis() >= expectedActivationAt) {
            scheduleSosActivationTimeout(expectedActivationAt = System.currentTimeMillis())
        } else {
            scheduleSosActivationTimeout(expectedActivationAt = expectedActivationAt)
        }
        ProtectionRuntimeBridge.recordPlatformEvent(
            context = context,
            type = "runtimeRecovered",
            reason = "pre_sos_rehydrated:$reason",
        )
    }

    private fun parsePreSosCycle(payload: List<Int>): PreSosPacketCycle? {
        if (payload.size < 4) {
            return null
        }
        val originatorNodeId = readU32OrNull(payload, 0) ?: return null
        val flagsOffset = when {
            payload.size >= 12 -> 10
            payload.size >= 7 -> 4
            else -> null
        }
        val packetId = flagsOffset?.let { offset ->
            if (payload.size > offset + 1) {
                val flagsWord = (payload[offset] and 0xFF) or
                    ((payload[offset + 1] and 0xFF) shl 8)
                flagsWord and 0x0F
            } else {
                null
            }
        }
        val cycleKey = if (packetId == null) {
            "sos:$originatorNodeId:${payloadHex(payload)}"
        } else {
            "sos:$originatorNodeId:$packetId"
        }
        return PreSosPacketCycle(
            cycleKey = cycleKey,
            originatorNodeId = originatorNodeId,
            packetId = packetId,
        )
    }

    private data class PreSosPacketCycle(
        val cycleKey: String,
        val originatorNodeId: Int,
        val packetId: Int?,
    )

    private val gattCallback =
        object : BluetoothGattCallback() {
            override fun onConnectionStateChange(
                gatt: BluetoothGatt,
                status: Int,
                newState: Int,
            ) {
                if (!isCurrentGattSession(gatt, "onConnectionStateChange")) {
                    return
                }
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
                        publishNativeCommandReadiness(
                            reason = "gatt_connected",
                            force = true,
                        )
                        backendHandoff.flushPendingActions("gatt_connected")
                        discoverServices(gatt)
                    }

                    BluetoothGatt.STATE_DISCONNECTED -> {
                        connectionInFlight = false
                        markSosStaleGuardLinkDropped("gatt_disconnected_$status")
                        closeCurrentGattSession("gatt_disconnected_$status")
                        clearCharacteristicRefs()
                        publishNativeCommandReadiness(
                            reason = "gatt_disconnected_$status",
                            force = true,
                        )
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
                if (!isCurrentGattSession(gatt, "onServicesDiscovered")) {
                    return
                }
                serviceDiscoveryTimeoutRunnable?.let(mainHandler::removeCallbacks)
                serviceDiscoveryTimeoutRunnable = null
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    configureSubscriptions(gatt)
                } else {
                    logNativeSessionDiscoveryResult(
                        serviceReady = false,
                        ea04Ready = false,
                        reason = "services_discovered_status_$status",
                    )
                    failCurrentNativeSession(gatt, "services_discovered_status_$status")
                }
            }

            override fun onDescriptorWrite(
                gatt: BluetoothGatt,
                descriptor: BluetoothGattDescriptor,
                status: Int,
            ) {
                if (!isCurrentGattSession(gatt, "onDescriptorWrite")) {
                    return
                }
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    failCurrentNativeSession(gatt, "descriptor_write_status_$status")
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
                if (!isCurrentGattSession(gatt, "onCharacteristicWrite")) {
                    return
                }
                val pending =
                    synchronized(commandLock) {
                        pendingCommandResult
                    } ?: return
                if (pending.gatt !== gatt || pending.characteristicUuid != characteristic.uuid) {
                    Log.w(
                        logTag,
                        "[SDK_BLE_COMMAND] action=callback_ignored reason=operation_mismatch " +
                            "expectedCharacteristic=${pending.characteristicUuid} " +
                            "actualCharacteristic=${characteristic.uuid}",
                    )
                    return
                }
                pending.timeoutRunnable?.let(mainHandler::removeCallbacks)
                val command = pending.command
                val terminalCancelSucceeded =
                    status == BluetoothGatt.GATT_SUCCESS &&
                        protectionTransportActionAfterSuccessfulCommand(command.label) ==
                        ProtectionSuccessfulCommandTransportAction.keepAliveAfterSosTerminal
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    val result =
                        "${command.label} native write succeeded via androidService."
                    runtimeStore.recordCommandResult(result)
                    recordGattWriteResult(
                        command = command,
                        characteristic = characteristic,
                        writeType = pending.writeType,
                        success = true,
                        status = status.toString(),
                    )
                    if (command.label == "SOS TRIGGER APP" || command.label == "SOS CONFIRM") {
                        Log.i(
                            logTag,
                            "SOS_DEVICE_COMMAND_WRITE_SUCCESS owner=androidService " +
                                "target=${redactDeviceTarget(targetDeviceId)} " +
                                "characteristic=${characteristic.uuid} " +
                                "gattStatus=$status note=gatt_write_completed_not_device_acknowledgement",
                        )
                    }
                    completePendingCommand(
                        pending,
                        commandResult(
                            success = true,
                            route = command.route,
                            result = result,
                            error = null,
                        ),
                    )
                } else {
                    val error =
                        "${command.label} native write failed with status $status."
                    runtimeStore.recordCommandError(
                        error,
                    )
                    recordGattWriteResult(
                        command = command,
                        characteristic = characteristic,
                        writeType = pending.writeType,
                        success = false,
                        status = status.toString(),
                    )
                    Log.w(
                        logTag,
                        "[SDK_BLE_COMMAND] action=failed label=${command.label} status=$status",
                    )
                    completePendingCommand(
                        pending,
                        commandResult(
                            success = false,
                            route = command.route,
                            result = null,
                            error = error,
                        ),
                    )
                }
                synchronized(commandLock) {
                    if (pendingCommandResult === pending) {
                        pendingCommandResult = null
                    }
                }
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    invalidateCommandPathAndReconnect(gatt, "command_write_status_$status")
                    return
                }
                if (terminalCancelSucceeded) {
                    Log.i(
                        logTag,
                        "SOS_NATIVE_CANCEL_TRANSPORT_PRESERVED " +
                            "gattConnected=${bluetoothGatt === gatt} " +
                            "subscriptionsActive=${subscriptionStep == SubscriptionStep.complete} " +
                            "nativeCommandReady=${lastPublishedCommandReadiness?.ready == true}",
                    )
                    Log.i(
                        logTag,
                        "SOS_TRANSPORT_TEARDOWN_DECISION " +
                            "trigger=sos_terminal_command_success action=preserve " +
                            "reason=incident_terminal_transport_persistent",
                    )
                }
                drainQueuedCommand(gatt)
            }

            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
            ) {
                if (!isCurrentGattSession(gatt, "onCharacteristicChanged")) {
                    return
                }
                handleIncomingPacket(gatt, characteristic, value)
            }

            @Deprecated("Deprecated in Java")
            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
            ) {
                if (!isCurrentGattSession(gatt, "onCharacteristicChangedLegacy")) {
                    return
                }
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
        private const val commandWriteTimeoutMs = 10_000L
        private const val serviceDiscoveryTimeoutMs = 10_000L
        private const val nativeWriteSubmitRejected = -1
        private const val sosActivationDelayMs = 20_000L
        private const val observedPreSosSkewMs = 2000L
        private const val logTag = "EixamProtectionBle"
        private val sosCommandOpcodes = setOf(0x04, 0x05, 0x06)

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
        val command: QueuedCommand,
        val gatt: BluetoothGatt,
        val characteristicUuid: UUID,
        val writeType: Int,
    ) {
        @Volatile
        var completed: Boolean = false

        var timeoutRunnable: Runnable? = null

        fun claimCompletion(): Boolean = synchronized(this) {
            if (completed) {
                false
            } else {
                completed = true
                true
            }
        }
    }

    private data class QueuedCommand(
        val label: String,
        val payload: ByteArray,
        val forceCmdCharacteristic: Boolean,
        val route: String,
        val completion: (Map<String, Any?>) -> Unit,
    )

}
