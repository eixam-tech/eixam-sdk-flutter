package dev.eixam.connect.flutter.protection

internal object ProtectionSosLifecycleLogic {
    fun onMeshPacket(currentState: ProtectionSosLifecycleState): ProtectionSosLifecycleState =
        when (currentState) {
            ProtectionSosLifecycleState.idle -> ProtectionSosLifecycleState.preConfirmSeen

            ProtectionSosLifecycleState.preConfirmSeen,
            ProtectionSosLifecycleState.createPending,
            ProtectionSosLifecycleState.cancelPending,
            -> currentState
        }

    fun onCountdownElapsed(currentState: ProtectionSosLifecycleState): ProtectionSosLifecycleState =
        when (currentState) {
            ProtectionSosLifecycleState.preConfirmSeen -> ProtectionSosLifecycleState.createPending
            else -> currentState
        }

    /**
     * [backendTerminal]: the close is the backend's own terminal relayed to the
     * TAG (`0xE3`, e.g. resolved in the portal). That is not a user cancel and
     * must never send a backend cancel.
     */
    fun onClosePacket(
        currentState: ProtectionSosLifecycleState,
        backendTerminal: Boolean = false,
    ): CloseOutcome =
        when (currentState) {
            ProtectionSosLifecycleState.createPending -> CloseOutcome(
                nextState = ProtectionSosLifecycleState.cancelPending,
                shouldCancelBackend = !backendTerminal,
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

    /**
     * Identity of the native SOS hand-off for one TAG cycle. The frame cycle
     * key (`sos:<node>:<4-bit packet id>`) repeats across SOS; the SDK fences
     * a pending SOS whose cycle equals the one it just closed, so a new SOS
     * with a recycled key was dropped as a replay. The cycle start makes it
     * unique per SOS and stable for the same cycle.
     */
    fun nativeHandoffCycleKey(frameCycleKey: String?, cycleStartedAt: Long?): String? {
        val key = frameCycleKey?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val started = cycleStartedAt?.takeIf { it > 0L } ?: return key
        return "$key@$started"
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
