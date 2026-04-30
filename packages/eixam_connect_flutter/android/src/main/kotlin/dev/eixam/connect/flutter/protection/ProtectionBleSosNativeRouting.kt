package dev.eixam.connect.flutter.protection

internal object ProtectionBleSosNativeRouting {
    fun route(
        classification: ProtectionBleSosIdentityClassification,
    ): ProtectionBleSosNativeRoute =
        when (classification) {
            ProtectionBleSosIdentityClassification.OwnSos,
            ProtectionBleSosIdentityClassification.OwnEvent -> ProtectionBleSosNativeRoute(
                observeLocalLifecycle = true,
                diagnosticEventType = "ownDeviceSosLifecycleObserved",
                emitSosEventReceived = false,
            )

            is ProtectionBleSosIdentityClassification.RemoteSos,
            is ProtectionBleSosIdentityClassification.RemoteEvent,
            is ProtectionBleSosIdentityClassification.UnknownOriginSos,
            is ProtectionBleSosIdentityClassification.UnknownOriginEvent -> ProtectionBleSosNativeRoute(
                observeLocalLifecycle = false,
                diagnosticEventType = null,
                emitSosEventReceived = true,
            )

            ProtectionBleSosIdentityClassification.Unknown ->
                ProtectionBleSosNativeRoute(
                    observeLocalLifecycle = false,
                    diagnosticEventType = null,
                    emitSosEventReceived = false,
                )
        }
}

internal data class ProtectionBleSosNativeRoute(
    val observeLocalLifecycle: Boolean,
    val diagnosticEventType: String?,
    val emitSosEventReceived: Boolean,
)
