package dev.eixam.connect.flutter.protection

internal enum class ProtectionNativePreparationFailure(val wireReason: String) {
    discoveryTimeout("native_service_discovery_timeout"),
    serviceAbsent("eixam_service_absent"),
    ea04Absent("ea04_absent"),
    identityMismatch("exact_identity_mismatch"),
    queueUnhealthy("operation_queue_unhealthy"),
}

internal enum class ProtectionSuccessfulCommandTransportAction {
    keepAlive,
    keepAliveAfterSosTerminal,
}

internal fun protectionTransportActionAfterSuccessfulCommand(
    commandLabel: String,
): ProtectionSuccessfulCommandTransportAction =
    if (commandLabel == "SOS CANCEL" || commandLabel == "SOS ACK") {
        ProtectionSuccessfulCommandTransportAction.keepAliveAfterSosTerminal
    } else {
        ProtectionSuccessfulCommandTransportAction.keepAlive
    }

internal fun evaluateProtectionNativePreparationFailure(
    gattConnected: Boolean,
    discoveryCompleted: Boolean,
    serviceReady: Boolean,
    ea04Ready: Boolean,
    identityReady: Boolean,
    queueHealthy: Boolean,
    discoveryTimedOut: Boolean,
): ProtectionNativePreparationFailure? {
    if (!gattConnected) {
        return null
    }
    if (discoveryTimedOut) {
        return ProtectionNativePreparationFailure.discoveryTimeout
    }
    if (!discoveryCompleted) {
        return null
    }
    if (!serviceReady) {
        return ProtectionNativePreparationFailure.serviceAbsent
    }
    if (!ea04Ready) {
        return ProtectionNativePreparationFailure.ea04Absent
    }
    if (!identityReady) {
        return ProtectionNativePreparationFailure.identityMismatch
    }
    if (!queueHealthy) {
        return ProtectionNativePreparationFailure.queueUnhealthy
    }
    return null
}

internal enum class ProtectionConnectPrecondition {
    ready,
    waitForBluetooth,
    noTarget,
}

/**
 * Once native owns the TAG link it never gives up because Bluetooth is off:
 * that is a wait (slow re-check, and an immediate reconnect on STATE_ON), not
 * the end of the reconnect loop.
 */
internal fun evaluateProtectionConnectPrecondition(
    adapterEnabled: Boolean,
    targetKnown: Boolean,
): ProtectionConnectPrecondition = when {
    !targetKnown -> ProtectionConnectPrecondition.noTarget
    !adapterEnabled -> ProtectionConnectPrecondition.waitForBluetooth
    else -> ProtectionConnectPrecondition.ready
}

/** Safety-net re-check while Bluetooth is off; STATE_ON reconnects at once. */
internal const val protectionBluetoothOffRecheckMs = 30_000L

internal const val protectionBluetoothOnWakeReason = "bluetooth_on"

internal fun shouldForceNativeBleReconnect(wakeReason: String): Boolean {
    // Only abort an in-flight native GATT after Flutter actually released
    // the radio, or after an adapter off/on cycle invalidated it. Matching
    // native_owner_ / native_ble_owner force-kills every skipped Flutter
    // campaign and attach/detach loops the SOS status stream.
    return wakeReason.contains("flutter_yielded") ||
        wakeReason == protectionBluetoothOnWakeReason
}
