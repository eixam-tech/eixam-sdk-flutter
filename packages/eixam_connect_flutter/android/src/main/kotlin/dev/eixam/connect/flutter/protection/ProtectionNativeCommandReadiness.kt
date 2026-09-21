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
            !owner -> "nativeOwner"
            !gattConnected -> "nativeGattConnected"
            !serviceReady -> "serviceDiscovered"
            !cmdEa04Ready -> "ea04Present"
            !identityReady -> "exactIdentityMatch"
            !queueHealthy -> "queueHealthy"
            else -> null
        }
}
