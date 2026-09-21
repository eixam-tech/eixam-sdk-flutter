package dev.eixam.connect.flutter.protection

internal enum class ProtectionNativeSessionAction {
    preparing,
    ready,
    restart,
}

internal fun evaluateProtectionNativeSessionAction(
    gattConnected: Boolean,
    serviceReady: Boolean,
    ea04Ready: Boolean,
    identityReady: Boolean,
    queueHealthy: Boolean,
    discoveryTimedOut: Boolean,
): ProtectionNativeSessionAction {
    if (
        gattConnected &&
        serviceReady &&
        ea04Ready &&
        identityReady &&
        queueHealthy
    ) {
        return ProtectionNativeSessionAction.ready
    }
    return if (gattConnected && discoveryTimedOut) {
        ProtectionNativeSessionAction.restart
    } else {
        ProtectionNativeSessionAction.preparing
    }
}
