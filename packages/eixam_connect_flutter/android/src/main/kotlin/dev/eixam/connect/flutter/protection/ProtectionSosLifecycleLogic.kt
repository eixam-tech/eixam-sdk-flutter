package dev.eixam.connect.flutter.protection

internal object ProtectionSosLifecycleLogic {
    fun onMeshPacket(currentState: ProtectionSosLifecycleState): ProtectionSosLifecycleState =
        when (currentState) {
            ProtectionSosLifecycleState.idle,
            ProtectionSosLifecycleState.cancelPending,
            -> ProtectionSosLifecycleState.preConfirmSeen

            ProtectionSosLifecycleState.preConfirmSeen,
            ProtectionSosLifecycleState.createPending,
            -> currentState
        }

    fun onCountdownElapsed(currentState: ProtectionSosLifecycleState): ProtectionSosLifecycleState =
        when (currentState) {
            ProtectionSosLifecycleState.preConfirmSeen -> ProtectionSosLifecycleState.createPending
            else -> currentState
        }

    fun onClosePacket(currentState: ProtectionSosLifecycleState): CloseOutcome =
        when (currentState) {
            ProtectionSosLifecycleState.createPending -> CloseOutcome(
                nextState = ProtectionSosLifecycleState.cancelPending,
                shouldCancelBackend = true,
            )

            ProtectionSosLifecycleState.preConfirmSeen,
            ProtectionSosLifecycleState.cancelPending,
            -> CloseOutcome(
                nextState = ProtectionSosLifecycleState.cancelPending,
                shouldCancelBackend = false,
            )

            ProtectionSosLifecycleState.idle -> CloseOutcome(
                nextState = ProtectionSosLifecycleState.idle,
                shouldCancelBackend = false,
            )
        }

    data class CloseOutcome(
        val nextState: ProtectionSosLifecycleState,
        val shouldCancelBackend: Boolean,
    )
}

internal enum class ProtectionSosLifecycleState {
    idle,
    preConfirmSeen,
    createPending,
    cancelPending,
}
