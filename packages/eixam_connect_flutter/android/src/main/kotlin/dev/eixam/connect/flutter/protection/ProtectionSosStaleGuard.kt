package dev.eixam.connect.flutter.protection

/**
 * F17b: the SDK closed a handed-over SOS (app cancel / backend resolve) but the
 * stop never reached the TAG, which keeps sending the frames of that SOS. The
 * guard sends the SDK's own terminal command to the TAG and never lets those
 * frames open a new SOS, without ever hiding a real new one.
 *
 * Firmware facts: every BLE SOS push is sent twice (SOS notify, then TEL
 * notify, ms apart). COUNTDOWN pushes every 500 ms in its first 2 s (4 pushes);
 * ACTIVE/ACK pushes once per retry (2, 8, 20, then every 60 s), and the 60 s
 * TEL resend barrier can be followed by an immediate retry (2 pushes close
 * together). So:
 * - a frame < [duplicateMs] after the previous accepted push is a copy: ignored;
 * - a candidate window opens at the first push; [burstPushes] distinct pushes
 *   within [burstWindowMs] = COUNTDOWN = a genuine new SOS (always admitted);
 * - [decideAfterMs] after the first push, fewer pushes = the closed SOS still
 *   running: stop again (notice once).
 * The guard ends on the TAG's close frame (`0xE1/0xE2/0xE3`), a frame gap over
 * [gapMs] while the link stayed up, [capMs] after arming, or a session change.
 * A link drop does not end it (A1); on reconnect the gap clock restarts and no
 * stop is written before a frame proves the closed SOS is still running.
 */
internal enum class ProtectionSosStaleTerminal(
    val wire: String,
    val stopPayload: ByteArray,
    val commandLabel: String,
) {
    cancel("cancel", byteArrayOf(0x04), "SOS CANCEL"),
    resolve("resolve", byteArrayOf(0x07), "SOS ACK"),
    ;

    companion object {
        fun fromWire(value: String?): ProtectionSosStaleTerminal? =
            entries.firstOrNull { it.wire == value?.trim() }
    }
}

internal data class ProtectionSosStaleGuardState(
    val terminal: ProtectionSosStaleTerminal,
    val nodeId: Int?,
    val armedAt: Long,
    /** Gap clock: last push of the closed SOS, the arm time or the reconnect time. */
    val lastFrameAt: Long,
    val linkDroppedSinceLastFrame: Boolean,
    val noticeShown: Boolean = false,
    /** Open candidate window (not persisted). */
    val candidateFirstAt: Long? = null,
    val candidatePushes: Int = 0,
    /** Last accepted (non-duplicate) push, for the duplicate-copy filter (not persisted). */
    val lastPushAt: Long? = null,
) {
    fun toPersisted(): Map<String, Any?> =
        mapOf(
            "terminal" to terminal.wire,
            "nodeId" to nodeId,
            "armedAt" to armedAt,
            "lastFrameAt" to lastFrameAt,
            "linkDroppedSinceLastFrame" to linkDroppedSinceLastFrame,
            "noticeShown" to noticeShown,
        )

    companion object {
        fun fromPersisted(values: Map<String, Any?>): ProtectionSosStaleGuardState? {
            val terminal = ProtectionSosStaleTerminal.fromWire(values["terminal"] as? String)
                ?: return null
            val armedAt = (values["armedAt"] as? Number)?.toLong() ?: return null
            return ProtectionSosStaleGuardState(
                terminal = terminal,
                nodeId = (values["nodeId"] as? Number)?.toInt(),
                armedAt = armedAt,
                lastFrameAt = (values["lastFrameAt"] as? Number)?.toLong() ?: armedAt,
                linkDroppedSinceLastFrame = values["linkDroppedSinceLastFrame"] as? Boolean ?: true,
                noticeShown = values["noticeShown"] as? Boolean ?: false,
            )
        }
    }
}

internal enum class ProtectionSosStaleAction {
    /** No guard: the frame follows the normal lifecycle. */
    notArmed,

    /** Another TAG's frame: the guard is untouched, the frame follows the normal lifecycle. */
    ignored,

    /** Copy of the previous push (SOS + TEL notify): swallowed. */
    duplicate,

    /** The guard ended; the frame follows the normal lifecycle. */
    disarmed,

    /** Inside a candidate window: swallowed until decided. */
    pending,

    /** COUNTDOWN burst: a genuine new SOS starting at [ProtectionSosStaleOutcome.startedAt]. */
    newSos,

    /** The closed SOS still running: stop it again. */
    stale,

    /** Nothing to do. */
    none,
}

internal data class ProtectionSosStaleOutcome(
    val action: ProtectionSosStaleAction,
    /** Next guard state; null once the guard ended. */
    val state: ProtectionSosStaleGuardState?,
    val sendStop: Boolean = false,
    val showNotice: Boolean = false,
    val startedAt: Long? = null,
    val reason: String? = null,
    /** Schedule [ProtectionSosStaleGuard.onDecide] at this time. */
    val decideAt: Long? = null,
) {
    /** Whether the frame goes to the normal lifecycle and to Dart. */
    val passesToLifecycle: Boolean
        get() = action == ProtectionSosStaleAction.notArmed ||
            action == ProtectionSosStaleAction.ignored ||
            action == ProtectionSosStaleAction.disarmed ||
            action == ProtectionSosStaleAction.newSos
}

internal object ProtectionSosStaleGuard {
    const val gapMs = 90_000L
    const val capMs = 600_000L
    const val duplicateMs = 300L
    const val burstWindowMs = 1_700L
    const val decideAfterMs = 2_000L
    const val burstPushes = 3
    const val recentFrameMs = 90_000L
    private const val decideToleranceMs = 100L

    /**
     * F17c-cdc: a cycle first seen this long ago is past its TAG countdown
     * burst (4 pushes in its first 2 s): no burst push of it can follow the SDK
     * terminal, so the guard classifies the rest. An app cancel during the
     * countdown with the TAG out of range never reaches it: the TAG goes ACTIVE
     * and its retries must be stopped, never a new SOS.
     */
    const val observedPastBurstMs = 2_000L

    /**
     * A handed-over SOS (like iOS): the native cycle reached createPending and
     * the SDK claimed its create; (F17c) Dart forwarded frames of this SOS past
     * its countdown burst ([observed]: native never saw the cycle because Dart
     * owned the link); or (F17c-cdc) the SDK cancelled the running native
     * countdown past its burst ([countdownStartedAt]). Never an unclaimed
     * native create.
     */
    fun shouldArm(
        terminal: ProtectionSosStaleTerminal?,
        lifecycleState: ProtectionSosLifecycleState,
        hasUnclaimedNativeCreate: Boolean,
        observed: ProtectionSosObservedCycle? = null,
        now: Long = 0L,
        countdownStartedAt: Long? = null,
    ): Boolean =
        terminal != null &&
            !hasUnclaimedNativeCreate &&
            (lifecycleState == ProtectionSosLifecycleState.createPending ||
                observedHandedOver(observed, now) ||
                cancelsRunningCountdown(terminal, lifecycleState, false, countdownStartedAt, now))

    /** F17c: Dart forwarded frames of this SOS past its countdown burst, recently. */
    fun observedHandedOver(observed: ProtectionSosObservedCycle?, now: Long): Boolean =
        observed != null &&
            now - observed.firstSeenAt >= observedPastBurstMs &&
            now - observed.lastSeenAt in 0..capMs

    /**
     * F17c-cdc: the SDK cancel of the running native countdown past its burst
     * ends it (the SDK already drops the create of a cycle cancelled after its
     * start, M5) and arms the guard: the TAG may never get the stop.
     */
    fun cancelsRunningCountdown(
        terminal: ProtectionSosStaleTerminal?,
        lifecycleState: ProtectionSosLifecycleState,
        hasUnclaimedNativeCreate: Boolean,
        countdownStartedAt: Long?,
        now: Long,
    ): Boolean =
        terminal == ProtectionSosStaleTerminal.cancel &&
            !hasUnclaimedNativeCreate &&
            lifecycleState == ProtectionSosLifecycleState.preConfirmSeen &&
            countdownStartedAt != null &&
            now - countdownStartedAt >= observedPastBurstMs

    /** F17c: an admitted Dart-forwarded push of the TAG's SOS; a long silence starts a new episode. */
    fun onObservedFrame(
        previous: ProtectionSosObservedCycle?,
        nodeId: Int?,
        now: Long,
    ): ProtectionSosObservedCycle {
        val sameTag = previous?.nodeId == null || nodeId == null ||
            normalize(previous.nodeId) == normalize(nodeId)
        if (previous == null || !sameTag || now - previous.lastSeenAt !in 0..gapMs) {
            return ProtectionSosObservedCycle(nodeId = nodeId, firstSeenAt = now, lastSeenAt = now)
        }
        return previous.copy(nodeId = previous.nodeId ?: nodeId, lastSeenAt = now)
    }

    /**
     * F17c: one own-TAG frame Dart received through its own BLE link. Native
     * is the only classifier: same guard, same copy collapse (which also merges
     * the same push arriving through both paths), same burst rule. A close
     * frame from any path ends the guard.
     */
    fun onForwardedFrame(
        state: ProtectionSosStaleGuardState?,
        observed: ProtectionSosObservedCycle?,
        frame: ProtectionSosForwardedFrame,
        now: Long,
    ): ProtectionSosForwardedDecision {
        if (frame.close) {
            return ProtectionSosForwardedDecision(
                outcome = ProtectionSosStaleOutcome(
                    ProtectionSosStaleAction.disarmed,
                    null,
                    reason = "tag_close",
                ),
                observed = null,
                verdict = ProtectionOwnTagSosVerdict.proceed,
            )
        }
        val outcome = onFrame(state, frame.nodeId, now)
        val verdict = ProtectionOwnTagSosVerdict.of(outcome)
        return ProtectionSosForwardedDecision(
            outcome = outcome,
            observed = if (verdict == ProtectionOwnTagSosVerdict.suppress) {
                observed
            } else {
                onObservedFrame(observed, frame.nodeId, now)
            },
            verdict = verdict,
        )
    }

    fun arm(
        terminal: ProtectionSosStaleTerminal,
        nodeId: Int?,
        now: Long,
        connected: Boolean,
    ): ProtectionSosStaleGuardState =
        ProtectionSosStaleGuardState(
            terminal = terminal,
            nodeId = nodeId,
            armedAt = now,
            lastFrameAt = now,
            linkDroppedSinceLastFrame = !connected,
        )

    /** Arm-time stop: the TAG is reachable and was still sending the SOS. */
    fun shouldSendStopOnArm(lastSosFrameAt: Long?, connected: Boolean, now: Long): Boolean =
        connected && lastSosFrameAt != null && now - lastSosFrameAt in 0..recentFrameMs

    /** Reconnect: no stop is written; the gap clock restarts. */
    fun onReconnected(state: ProtectionSosStaleGuardState, now: Long): ProtectionSosStaleGuardState =
        state.copy(
            lastFrameAt = now,
            linkDroppedSinceLastFrame = false,
            candidateFirstAt = null,
            candidatePushes = 0,
        )

    fun onLinkDropped(state: ProtectionSosStaleGuardState): ProtectionSosStaleGuardState =
        state.copy(linkDroppedSinceLastFrame = true, candidateFirstAt = null, candidatePushes = 0)

    fun isExpired(state: ProtectionSosStaleGuardState, now: Long): Boolean =
        now - state.armedAt > capMs

    /** The TAG sent its own close: it got the stop (or closed the SOS itself). */
    @Suppress("UNUSED_PARAMETER")
    fun onTagClose(state: ProtectionSosStaleGuardState?): ProtectionSosStaleGuardState? = null

    /** Session change: nothing of the previous account survives. */
    @Suppress("UNUSED_PARAMETER")
    fun onSessionChanged(state: ProtectionSosStaleGuardState?): ProtectionSosStaleGuardState? = null

    fun onFrame(
        state: ProtectionSosStaleGuardState?,
        frameNodeId: Int?,
        now: Long,
    ): ProtectionSosStaleOutcome {
        state ?: return ProtectionSosStaleOutcome(ProtectionSosStaleAction.notArmed, null)
        if (frameNodeId != null && state.nodeId != null &&
            normalize(frameNodeId) != normalize(state.nodeId)
        ) {
            return ProtectionSosStaleOutcome(ProtectionSosStaleAction.ignored, state)
        }
        if (isExpired(state, now)) {
            return ProtectionSosStaleOutcome(ProtectionSosStaleAction.disarmed, null, reason = "cap")
        }
        val lastPush = state.lastPushAt
        if (lastPush != null && now - lastPush in 0 until duplicateMs) {
            return ProtectionSosStaleOutcome(ProtectionSosStaleAction.duplicate, state)
        }
        var current = state
        var sendStop = false
        var showNotice = false
        val first = current.candidateFirstAt
        if (first != null) {
            if (now - first <= burstWindowMs) {
                val pushes = current.candidatePushes + 1
                if (pushes >= burstPushes) {
                    return ProtectionSosStaleOutcome(
                        ProtectionSosStaleAction.newSos,
                        null,
                        startedAt = first,
                        reason = "countdown_burst",
                    )
                }
                return ProtectionSosStaleOutcome(
                    ProtectionSosStaleAction.pending,
                    current.copy(candidatePushes = pushes, lastPushAt = now),
                )
            }
            // A later push: the old candidate was the closed SOS; then a new window.
            val resolved = resolveStale(current)
            current = resolved.state!!
            sendStop = resolved.sendStop
            showNotice = resolved.showNotice
        }
        if (!current.linkDroppedSinceLastFrame && now - current.lastFrameAt > gapMs) {
            return ProtectionSosStaleOutcome(ProtectionSosStaleAction.disarmed, null, reason = "gap")
        }
        return ProtectionSosStaleOutcome(
            action = ProtectionSosStaleAction.pending,
            state = current.copy(candidateFirstAt = now, candidatePushes = 1, lastPushAt = now),
            sendStop = sendStop,
            showNotice = showNotice,
            decideAt = now + decideAfterMs,
        )
    }

    /** [decideAfterMs] after the candidate's first push. */
    fun onDecide(state: ProtectionSosStaleGuardState, now: Long): ProtectionSosStaleOutcome {
        val first = state.candidateFirstAt
            ?: return ProtectionSosStaleOutcome(ProtectionSosStaleAction.none, state)
        if (now - first < decideAfterMs - decideToleranceMs) {
            return ProtectionSosStaleOutcome(ProtectionSosStaleAction.none, state)
        }
        if (state.candidatePushes >= burstPushes) {
            return ProtectionSosStaleOutcome(
                ProtectionSosStaleAction.newSos,
                null,
                startedAt = first,
                reason = "countdown_burst",
            )
        }
        return resolveStale(state)
    }

    private fun resolveStale(state: ProtectionSosStaleGuardState): ProtectionSosStaleOutcome =
        ProtectionSosStaleOutcome(
            action = ProtectionSosStaleAction.stale,
            state = state.copy(
                lastFrameAt = state.lastPushAt ?: state.candidateFirstAt ?: state.lastFrameAt,
                linkDroppedSinceLastFrame = false,
                noticeShown = true,
                candidateFirstAt = null,
                candidatePushes = 0,
            ),
            sendStop = true,
            showNotice = !state.noticeShown,
        )

    private fun normalize(nodeId: Int): Long = nodeId.toLong() and 0xFFFF_FFFFL
}

/** F17c: what native saw of an SOS through Dart's forwarded frames (persisted). */
internal data class ProtectionSosObservedCycle(
    val nodeId: Int?,
    val firstSeenAt: Long,
    val lastSeenAt: Long,
)

/** F17c: Dart's answer for one forwarded own-TAG frame. */
internal enum class ProtectionOwnTagSosVerdict {
    /** Not guarded (or the guard ended): Dart handles the frame exactly as before. */
    proceed,

    /** A countdown burst under the guard: a genuine new SOS; Dart handles the frame. */
    newSos,

    /** A copy, a frame still being classified, or the closed SOS: Dart drops it. */
    suppress,
    ;

    companion object {
        fun of(outcome: ProtectionSosStaleOutcome): ProtectionOwnTagSosVerdict =
            when (outcome.action) {
                ProtectionSosStaleAction.notArmed,
                ProtectionSosStaleAction.ignored,
                ProtectionSosStaleAction.disarmed,
                -> proceed

                ProtectionSosStaleAction.newSos -> newSos
                else -> suppress
            }
    }
}

internal data class ProtectionSosForwardedDecision(
    val outcome: ProtectionSosStaleOutcome,
    val observed: ProtectionSosObservedCycle?,
    val verdict: ProtectionOwnTagSosVerdict,
)

/** F17c: the raw frame Dart forwarded, parsed like the native frame path. */
internal data class ProtectionSosForwardedFrame(
    val close: Boolean,
    val nodeId: Int?,
) {
    companion object {
        /** null: not an SOS frame (Dart handles it as before). */
        fun parse(raw: List<Int>): ProtectionSosForwardedFrame? {
            if (raw.any { it !in 0..0xFF }) return null
            val payload = ProtectionBleSosIdentityClassifier.boundSosBody(raw) ?: raw
            return when (payload.size) {
                4, 6 -> {
                    val opcode = payload[0]
                    val subcode = payload[1]
                    val close = (opcode == 0xE1 && (subcode == 0x01 || subcode == 0x02)) ||
                        ((opcode == 0xE2 || opcode == 0xE3) && subcode in 0x01..0x03)
                    if (!close) {
                        null
                    } else {
                        ProtectionSosForwardedFrame(close = true, nodeId = readU32(payload, 2))
                    }
                }

                5, 10 -> ProtectionSosForwardedFrame(close = false, nodeId = null)
                7, 12 -> ProtectionSosForwardedFrame(close = false, nodeId = readU32(payload, 0))
                else -> null
            }
        }

        private fun readU32(payload: List<Int>, offset: Int): Int? {
            if (payload.size < offset + 4) return null
            return payload[offset] or
                (payload[offset + 1] shl 8) or
                (payload[offset + 2] shl 16) or
                (payload[offset + 3] shl 24)
        }
    }
}
