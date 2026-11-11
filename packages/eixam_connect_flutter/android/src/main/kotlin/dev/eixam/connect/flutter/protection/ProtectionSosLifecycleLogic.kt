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
     * Whether a native pending SOS create is already on the backend and can be
     * retired natively instead of being handed to the SDK. Only when the stored
     * backend incident belongs to this same TAG cycle: the stored id is never
     * cleared when an SOS ends, so an incident of an earlier SOS (cancelled
     * from the app) retired every later background TAG SOS, which then never
     * reached the backend (F7 Android). Hand-off cycle keys are unique per SOS
     * (`nativeHandoffCycleKey`); anything else stays pending for the SDK, which
     * confirms an already open incident itself.
     */
    fun isNativeCreateAlreadySynced(
        activeBackendIncidentId: String?,
        activeBackendIncidentLifecycleId: String?,
        pendingCreateCycleKey: String?,
    ): Boolean {
        if (activeBackendIncidentId.isNullOrBlank()) return false
        val incidentCycle = activeBackendIncidentLifecycleId?.trim()
        val pendingCycle = pendingCreateCycleKey?.trim()
        return !incidentCycle.isNullOrEmpty() && incidentCycle == pendingCycle
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
