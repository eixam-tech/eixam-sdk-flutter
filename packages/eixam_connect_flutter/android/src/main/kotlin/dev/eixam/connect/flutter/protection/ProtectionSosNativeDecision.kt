package dev.eixam.connect.flutter.protection

/**
 * F17c: the runtime owner's own-TAG SOS decisions, pure (no Android types), so
 * the shared scenario fixture (`test/fixtures/stale_sos_guard_scenarios.txt`)
 * drives exactly the code production runs: frame classification, the stale
 * guard, the native lifecycle step and the SDK-terminal arming rule.
 * [ProtectionBleRuntimeOwner] applies the side effects (persistence, timers,
 * notifications, TAG writes).
 */
internal object ProtectionSosNativeDecision {
    /**
     * The TAG's own close frame (firmware 07 §1.2, 6 B `[evt][sub][nodeId u32 LE]`):
     * `0xE1` device cancel (sub `0x01` countdown / `0x02` fired), `0xE2` app
     * cancel ack and `0xE3` backend resolve ack (sub `0x01..0x03`). Returns the
     * opcode, or null when [payload] is not a close frame.
     */
    fun closeOpcode(payload: List<Int>): Int? {
        if (payload.size != 4 && payload.size != 6) return null
        val opcode = payload[0] and 0xFF
        val subcode = payload[1] and 0xFF
        val closed = (opcode == 0xE1 && (subcode == 0x01 || subcode == 0x02)) ||
            ((opcode == 0xE2 || opcode == 0xE3) && subcode in 0x01..0x03)
        return if (closed) opcode else null
    }

    /** The SOS originator: bound receipt body, 6 B event, or 7/12 B SOS frame. */
    fun originatorNodeId(payload: List<Int>): Int? {
        ProtectionBleSosIdentityClassifier.boundSosBody(payload)?.let { return readU32(it, 0) }
        if (payload.size == 6 && (payload[0] == 0xE1 || payload[0] == 0xE2 || payload[0] == 0xE3)) {
            return readU32(payload, 2)
        }
        if (payload.size == 7 || payload.size == 12) {
            return readU32(payload, 0)
        }
        return null
    }

    data class FrameStep(
        val outcome: ProtectionSosStaleOutcome,
        /** The frame goes to the native lifecycle and to Dart. */
        val passes: Boolean,
        val nextLifecycle: ProtectionSosLifecycleState,
        /**
         * Non-null: this frame starts the native TAG countdown, observed at this
         * time (a guard burst: its first push). The owner applies its pre-SOS skew.
         */
        val countdownObservedAt: Long?,
    )

    /** One own-TAG countdown/active frame on the native GATT path. */
    fun onSosFrame(
        guard: ProtectionSosStaleGuardState?,
        lifecycle: ProtectionSosLifecycleState,
        payload: List<Int>,
        now: Long,
    ): FrameStep {
        val outcome = ProtectionSosStaleGuard.onFrame(guard, originatorNodeId(payload), now)
        if (!outcome.passesToLifecycle) {
            // The closed SOS, a copy, or still deciding: never a new SOS.
            return FrameStep(outcome, passes = false, nextLifecycle = lifecycle, countdownObservedAt = null)
        }
        val next = ProtectionSosLifecycleLogic.onMeshPacket(lifecycle)
        val starts = next == ProtectionSosLifecycleState.preConfirmSeen &&
            lifecycle != ProtectionSosLifecycleState.preConfirmSeen
        val observedAt = if (outcome.action == ProtectionSosStaleAction.newSos) outcome.startedAt ?: now else now
        return FrameStep(outcome, passes = true, nextLifecycle = next, countdownObservedAt = observedAt.takeIf { starts })
    }

    data class TerminalStep(
        val nextLifecycle: ProtectionSosLifecycleState,
        /** Arm the "unconfirmed stop" record. */
        val arm: Boolean,
        /**
         * F17c Phase 2 / item 1: why the stop was ignored (nothing changes):
         * `cycle_id_mismatch` (it names another, older cycle), `no_cycle_id`
         * (an automated stop naming none), `issued_before_current_cycle`,
         * `user_stop_for_older_cycle` (F1: the user's stop of the cycle seen
         * at the tap, arrived after a newer one began). Null: applied.
         */
        val ignoredReason: String? = null,
    ) {
        val staleIgnored: Boolean get() = ignoredReason != null
    }

    /**
     * The SDK ended an own-TAG SOS (Dart `closeNativeSosCycle`). F17c-cdc: the
     * cancel of this TAG's running countdown ends it; a handed-over create
     * closes (M5). The record arms by [ProtectionSosStaleGuard.shouldArm]
     * (L1: a countdown only for the same TAG, as on iOS).
     */
    fun onSdkTerminal(
        terminal: ProtectionSosStaleTerminal?,
        lifecycle: ProtectionSosLifecycleState,
        lifecycleNodeId: Int?,
        terminalNodeId: Int?,
        hasUnclaimedNativeCreate: Boolean,
        countdownStartedAt: Long?,
        observed: ProtectionSosObservedCycle?,
        now: Long,
        issuedAt: Long? = null,
        target: ProtectionSosStopTarget = ProtectionSosStopTarget.CurrentCycle(),
        currentCycleId: String? = null,
    ): TerminalStep {
        val sameTag = sameTag(terminalNodeId, lifecycleNodeId)
        when (target) {
            // The user's own action: the cycle running now, unless (F1) it
            // names another cycle seen at the tap and the current one began
            // after the tap (the user stopped an older SOS).
            is ProtectionSosStopTarget.CurrentCycle -> {
                val tapCycleId = target.tapCycleId
                if (!tapCycleId.isNullOrEmpty() && tapCycleId != currentCycleId && issuedAt != null) {
                    val currentStart = currentCycleStartedAt(
                        lifecycle = lifecycle,
                        countdownStartedAt = countdownStartedAt.takeIf { sameTag },
                        observed = observed,
                        terminalNodeId = terminalNodeId,
                        now = now,
                    )
                    if (currentStart != null && issuedAt < currentStart) {
                        return TerminalStep(
                            lifecycle,
                            arm = false,
                            ignoredReason = "user_stop_for_older_cycle",
                        )
                    }
                }
            }
            ProtectionSosStopTarget.Missing ->
                return TerminalStep(lifecycle, arm = false, ignoredReason = "no_cycle_id")
            is ProtectionSosStopTarget.Cycle -> {
                if (target.id != currentCycleId) {
                    // F17c item 1: an older SOS's stop, delivered after a newer
                    // cycle opened: the running cycle is never touched.
                    return TerminalStep(lifecycle, arm = false, ignoredReason = "cycle_id_mismatch")
                }
                val currentStart = currentCycleStartedAt(
                    lifecycle = lifecycle,
                    countdownStartedAt = countdownStartedAt.takeIf { sameTag },
                    observed = observed,
                    terminalNodeId = terminalNodeId,
                    now = now,
                )
                if (issuedAt != null && currentStart != null && issuedAt < currentStart) {
                    // F17c Phase 2: a stop issued before the current countdown
                    // began targets an older SOS.
                    return TerminalStep(
                        lifecycle,
                        arm = false,
                        ignoredReason = "issued_before_current_cycle",
                    )
                }
            }
        }
        val nextLifecycle =
            if (ProtectionSosStaleGuard.cancelsRunningCountdown(
                    terminal,
                    lifecycle,
                    hasUnclaimedNativeCreate,
                    countdownStartedAt?.takeIf { sameTag },
                    now,
                )
            ) {
                ProtectionSosLifecycleState.idle
            } else {
                ProtectionSosLifecycleLogic.onSdkClose(lifecycle, hasUnclaimedNativeCreate)
            }
        val arm = ProtectionSosStaleGuard.shouldArm(
            terminal,
            lifecycle,
            hasUnclaimedNativeCreate,
            observed,
            now,
            sameTagAsCycle = sameTag,
        )
        return TerminalStep(nextLifecycle, arm)
    }

    data class PromptSosStep(
        /** Native opens the SOS (createPending, as a TAG SOS whose countdown elapsed). */
        val opensNativeSos: Boolean,
        /** Show the active notification and queue the create for the SDK. */
        val queuesCreate: Boolean,
    )

    /**
     * F17c: the prompt's "Send SOS" or its timeout. Native opens the SOS only
     * while its lifecycle is idle; a native SOS already running is delivered
     * by itself (no second create, no notification for an SOS not opened).
     */
    fun onPromptSos(lifecycle: ProtectionSosLifecycleState): PromptSosStep {
        val opens = lifecycle == ProtectionSosLifecycleState.idle
        return PromptSosStep(opensNativeSos = opens, queuesCreate = opens)
    }

    /**
     * F17c Phase 2: when the countdown running for the terminal's TAG began
     * (the newest of the native cycle and the Dart-forwarded burst), null when
     * none runs (iOS `currentCycleStartedAt`).
     */
    fun currentCycleStartedAt(
        lifecycle: ProtectionSosLifecycleState,
        countdownStartedAt: Long?,
        observed: ProtectionSosObservedCycle?,
        terminalNodeId: Int?,
        now: Long,
    ): Long? {
        val starts = mutableListOf<Long>()
        if (lifecycle != ProtectionSosLifecycleState.idle && countdownStartedAt != null) {
            starts.add(countdownStartedAt)
        }
        if (observed != null &&
            ProtectionSosStaleGuard.observedRecently(observed, now) &&
            sameTag(terminalNodeId, observed.nodeId)
        ) {
            starts.add(observed.firstSeenAt)
        }
        return starts.maxOrNull()
    }

    /**
     * F17c item 1 (iOS `openCycleId`): the cycle id after a cycle opens for a
     * TAG. It joins the cycle already open for that TAG on the other path (the
     * same SOS seen by Dart and native, e.g. a BLE owner handover); otherwise
     * it is a new SOS: [newId].
     */
    fun cycleIdOnOpen(currentId: String?, alreadyOpen: Boolean, newId: () -> String): String =
        if (alreadyOpen && currentId != null) currentId else newId()

    /** F17c item 1: the native countdown / SOS runs for [nodeId]. */
    fun nativeCycleOpen(
        lifecycle: ProtectionSosLifecycleState,
        lifecycleNodeId: Int?,
        nodeId: Int?,
    ): Boolean = lifecycle != ProtectionSosLifecycleState.idle && sameTag(nodeId, lifecycleNodeId)

    /** F17c item 1: Dart forwarded [nodeId]'s SOS frames recently. */
    fun dartCycleOpen(observed: ProtectionSosObservedCycle?, nodeId: Int?, now: Long): Boolean =
        observed != null && ProtectionSosStaleGuard.observedRecently(observed, now) &&
            sameTag(nodeId, observed.nodeId)

    /**
     * F17c item 1: a Dart-forwarded frame moved the observed cycle from
     * [previous] to [next]: a fresh episode opens a cycle (joining the native
     * one of that TAG, or the recent Dart one of the same TAG).
     */
    fun dartCycleOpened(
        previous: ProtectionSosObservedCycle?,
        next: ProtectionSosObservedCycle?,
    ): Boolean = next != null && next.firstSeenAt == next.lastSeenAt &&
        (previous == null || previous.firstSeenAt != next.firstSeenAt)

    /** Same TAG unless both ids are known and differ (iOS `sameNode`). */
    fun sameTag(a: Int?, b: Int?): Boolean =
        a == null || b == null || (a.toLong() and 0xFFFF_FFFFL) == (b.toLong() and 0xFFFF_FFFFL)

    private fun readU32(payload: List<Int>, offset: Int): Int? {
        if (payload.size < offset + 4) return null
        return (payload[offset] and 0xFF) or
            ((payload[offset + 1] and 0xFF) shl 8) or
            ((payload[offset + 2] and 0xFF) shl 16) or
            ((payload[offset + 3] and 0xFF) shl 24)
    }
}

/** F17c item 1: which native cycle an SDK stop / close targets. */
internal sealed class ProtectionSosStopTarget {
    /**
     * The user's own action (or the session change): the cycle running now.
     * F1 (Roger 17/11/2026): [tapCycleId] is the native cycle id the SDK
     * captured at the user's tap (null: none known, and always for the session
     * change); see [ProtectionSosNativeDecision.onSdkTerminal].
     */
    data class CurrentCycle(val tapCycleId: String? = null) : ProtectionSosStopTarget()

    /** An automated stop: only the native cycle with this id. */
    data class Cycle(val id: String) : ProtectionSosStopTarget()

    /** An automated stop naming no cycle: never applied. */
    object Missing : ProtectionSosStopTarget()

    companion object {
        /** The channel arguments (`targetCurrentCycle`, `targetCycleId`). */
        fun fromArguments(targetCurrentCycle: Boolean, targetCycleId: String?): ProtectionSosStopTarget =
            when {
                targetCurrentCycle -> CurrentCycle(tapCycleId = targetCycleId?.takeIf { it.isNotEmpty() })
                !targetCycleId.isNullOrEmpty() -> Cycle(targetCycleId)
                else -> Missing
            }
    }
}
