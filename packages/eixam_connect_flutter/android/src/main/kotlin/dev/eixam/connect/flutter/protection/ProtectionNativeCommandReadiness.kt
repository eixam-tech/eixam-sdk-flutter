package dev.eixam.connect.flutter.protection

internal data class ProtectionNativeCommandReadiness(
    val owner: Boolean,
    val gattConnected: Boolean,
    val serviceReady: Boolean,
    val cmdEa04Ready: Boolean,
    val identityReady: Boolean,
    val queueHealthy: Boolean,
) {
    val ready: Boolean
        get() = owner &&
            gattConnected &&
            serviceReady &&
            cmdEa04Ready &&
            identityReady &&
            queueHealthy

    val falsePredicate: String?
        get() = when {
            !owner -> "owner"
            !gattConnected -> "gattConnected"
            !serviceReady -> "serviceReady"
            !cmdEa04Ready -> "cmdEa04Ready"
            !identityReady -> "identityReady"
            !queueHealthy -> "queueHealthy"
            else -> null
        }
}
