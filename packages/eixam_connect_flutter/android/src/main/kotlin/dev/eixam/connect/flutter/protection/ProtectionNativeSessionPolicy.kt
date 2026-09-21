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
    if (commandLabel == "SOS CANCEL") {
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
