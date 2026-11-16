package dev.eixam.connect.flutter.protection

/**
 * F17b/F17c: the SDK closed an own-TAG SOS (app cancel / backend resolve) the
 * TAG never confirmed closing: the "unconfirmed stop" record. Without a
 * firmware episode id, a non-burst frame under it is AMBIGUOUS (the closed SOS
 * still running, or a genuine SOS pressed out of range): the user is asked
 * (prompt, native 30 s timeout sends the SOS). It never stops the TAG and never
 * drops a frame without the user's answer; after the user's "No" (consent for
 * [consentMs]) the matching stop is written again on the next retry.
 *
 * Firmware facts: every BLE SOS push is sent twice (SOS notify, then TEL
 * notify, ms apart). COUNTDOWN pushes every 500 ms in its first 2 s (4 pushes);
 * ACTIVE/ACK pushes once per retry (2, 8, 20, then every 60 s), and the 60 s
 * TEL resend barrier can be followed by an immediate retry (2 pushes close
 * together). So:
 * - a frame < [duplicateMs] after the previous accepted push is a copy: ignored;
 * - a candidate window opens at the first push; [burstPushes] distinct pushes
 *   within [burstWindowMs] = COUNTDOWN = a genuine new SOS (always admitted);
 * - [decideAfterMs] after the first push, fewer pushes = ambiguous: prompt
 *   (once; a later retry while it is open never re-prompts).
 * The record ends on the TAG's close frame (`0xE1/0xE2/0xE3`), a countdown
 * burst, the user's send / the timeout, a frame gap over [gapMs] while the link
 * stayed up, [capMs] after arming, a new SDK SOS or a session change. A link
 * drop does not end it (A1).
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
    /** F17c prompt: open until this time (the native timeout then sends the SOS). */
    val promptDeadlineAt: Long? = null,
    /** F17c prompt: the user's "No" (stop the TAG), consent for [ProtectionSosStaleGuard.consentMs]. */
    val stopConfirmedAt: Long? = null,
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
            "promptDeadlineAt" to promptDeadlineAt,
            "stopConfirmedAt" to stopConfirmedAt,
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
                promptDeadlineAt = (values["promptDeadlineAt"] as? Number)?.toLong(),
                stopConfirmedAt = (values["stopConfirmedAt"] as? Number)?.toLong(),
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

    /** The user already answered "No" (within [ProtectionSosStaleGuard.consentMs]): stop it again. */
    stale,

    /** F17c: ambiguous: ask the user ([ProtectionSosStaleOutcome.openPrompt] when newly opened). */
    prompt,

    /** F17c: the user's "Send SOS" or the prompt timeout: native opens the SOS (create). */
    sosOpened,

    /** F17c: the user's "No": write the matching stop, open nothing. */
    stop,

    /** Nothing to do. */
    none,
}

internal data class ProtectionSosStaleOutcome(
    val action: ProtectionSosStaleAction,
    /** Next guard state; null once the guard ended. */
    val state: ProtectionSosStaleGuardState?,
    val sendStop: Boolean = false,
    /** F17c: show the prompt (notification + SDK event) until [ProtectionSosStaleGuardState.promptDeadlineAt]. */
    val openPrompt: Boolean = false,
    /** F17c: an open prompt ends (answered, timeout, burst, TAG close, cap, session, new SDK SOS). */
    val closePrompt: Boolean = false,
    /** F17c: open the SOS through the native create (send / timeout). */
    val openSos: Boolean = false,
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

    /** F17c: the record asks instead of stopping, so it lives up to a day (a TAG long out of range). */
    const val capMs = 86_400_000L

    /** F17c: the native prompt timeout; no answer sends the SOS. */
    const val promptMs = 30_000L

    /** F17c: the user's "No" lets later retries be stopped without asking for this long. */
    const val consentMs = 600_000L

    /** F17c: an SOS Dart forwarded frames of this recently was seen (arms the record). */
    const val observedRecentMs = 600_000L
    const val duplicateMs = 300L
    const val burstWindowMs = 1_700L
    const val decideAfterMs = 2_000L
    const val burstPushes = 3
    const val recentFrameMs = 90_000L
    private const val decideToleranceMs = 100L

    /** F17c M-C: a Dart receive time older than this (or in the future) is not trusted. */
    const val forwardedFrameMaxAgeMs = 5_000L

    /**
     * F17c ONE rule on every platform: any SDK cancel/resolve of an own-TAG SOS
     * seen on any path arms the "unconfirmed stop" record: a handed-over native
     * create, a native countdown, or frames Dart forwarded ([observed]). Never
     * while native still owes an unclaimed create of that SOS (the terminal is
     * not a stop of it).
     */
    fun shouldArm(
        terminal: ProtectionSosStaleTerminal?,
        lifecycleState: ProtectionSosLifecycleState,
        hasUnclaimedNativeCreate: Boolean,
        observed: ProtectionSosObservedCycle? = null,
        now: Long = 0L,
    ): Boolean =
        terminal != null &&
            !hasUnclaimedNativeCreate &&
            (lifecycleState == ProtectionSosLifecycleState.createPending ||
                lifecycleState == ProtectionSosLifecycleState.preConfirmSeen ||
                observedRecently(observed, now))

    /** F17c: Dart forwarded frames of this TAG's SOS recently. */
    fun observedRecently(observed: ProtectionSosObservedCycle?, now: Long): Boolean =
        observed != null && now - observed.lastSeenAt in 0..observedRecentMs

    /**
     * F17c-cdc: the SDK cancel of this TAG's running native countdown ends it:
     * it is never promoted into a native create at its deadline (the SDK
     * already drops the create of a cycle cancelled after its start, M5). The
     * record arms as for any other unconfirmed stop ([shouldArm]).
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
            now >= countdownStartedAt

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
        receivedAt: Long? = null,
    ): ProtectionSosForwardedDecision {
        if (frame.close && state != null && frame.nodeId != null && state.nodeId != null &&
            normalize(frame.nodeId) != normalize(state.nodeId)
        ) {
            // Another TAG's close never ends this guard.
            return ProtectionSosForwardedDecision(
                outcome = ProtectionSosStaleOutcome(ProtectionSosStaleAction.ignored, state),
                observed = observed,
                verdict = ProtectionOwnTagSosVerdict.proceed,
            )
        }
        if (frame.close) {
            return ProtectionSosForwardedDecision(
                outcome = ProtectionSosStaleOutcome(
                    ProtectionSosStaleAction.disarmed,
                    null,
                    reason = "tag_close",
                    closePrompt = state?.promptDeadlineAt != null,
                ),
                observed = null,
                verdict = ProtectionOwnTagSosVerdict.proceed,
            )
        }
        val outcome = onFrame(
            state,
            frame.nodeId,
            forwardedFrameAt(state, receivedAt, now),
            deliveredAt = now,
        )
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

    /**
     * F17c M-C: when a Dart-forwarded push happened. Dart's receive time when
     * plausible (not in the future, at most [forwardedFrameMaxAgeMs] old), so
     * pushes delivered late together still count as distinct pushes; else the
     * native clock. Never before the last counted push: a late copy of a push
     * already counted (other path) stays a copy.
     */
    fun forwardedFrameAt(state: ProtectionSosStaleGuardState?, receivedAt: Long?, now: Long): Long {
        val plausible = receivedAt?.takeIf { it <= now && now - it <= forwardedFrameMaxAgeMs } ?: now
        val lastPush = state?.lastPushAt ?: return plausible
        return if (plausible < lastPush && lastPush <= now) lastPush else plausible
    }

    /**
     * F17c M-B: Dart's own link note (also a native<->Dart owner handover).
     * Like iOS noteLinkUp: the gap clock restarts, but a burst being counted
     * (and its pending decision) is kept: a flip mid-countdown must never turn
     * a genuine new SOS into a stale stop.
     */
    fun onForwardedLinkUp(state: ProtectionSosStaleGuardState, now: Long): ProtectionSosStaleGuardState =
        state.copy(lastFrameAt = now, linkDroppedSinceLastFrame = false)

    /** F17c M-B: like iOS noteLinkDropped: the open candidate is kept. */
    fun onForwardedLinkDropped(state: ProtectionSosStaleGuardState): ProtectionSosStaleGuardState =
        state.copy(linkDroppedSinceLastFrame = true)

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

    /**
     * [now] is when the push happened; [deliveredAt] when it reached native
     * (they differ only for a late Dart-forwarded push): the decision is
     * scheduled from delivery, so late pushes of the burst still arrive first.
     */
    fun onFrame(
        state: ProtectionSosStaleGuardState?,
        frameNodeId: Int?,
        now: Long,
        deliveredAt: Long = now,
    ): ProtectionSosStaleOutcome {
        state ?: return ProtectionSosStaleOutcome(ProtectionSosStaleAction.notArmed, null)
        if (frameNodeId != null && state.nodeId != null &&
            normalize(frameNodeId) != normalize(state.nodeId)
        ) {
            return ProtectionSosStaleOutcome(ProtectionSosStaleAction.ignored, state)
        }
        if (isExpired(state, now)) {
            return ProtectionSosStaleOutcome(
                ProtectionSosStaleAction.disarmed,
                null,
                reason = "cap",
                closePrompt = state.promptDeadlineAt != null,
            )
        }
        val lastPush = state.lastPushAt
        if (lastPush != null && now - lastPush in 0 until duplicateMs) {
            return ProtectionSosStaleOutcome(ProtectionSosStaleAction.duplicate, state)
        }
        var current = state
        var sendStop = false
        var openPrompt = false
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
                        closePrompt = current.promptDeadlineAt != null,
                    )
                }
                return ProtectionSosStaleOutcome(
                    ProtectionSosStaleAction.pending,
                    current.copy(candidatePushes = pushes, lastPushAt = now),
                )
            }
            // A later push: the old candidate was decided late (no burst); then a new window.
            val resolved = resolveDecision(current, now)
            current = resolved.state!!
            sendStop = resolved.sendStop
            openPrompt = resolved.openPrompt
        }
        if (!current.linkDroppedSinceLastFrame && now - current.lastFrameAt > gapMs) {
            return ProtectionSosStaleOutcome(
                ProtectionSosStaleAction.disarmed,
                null,
                reason = "gap",
                closePrompt = current.promptDeadlineAt != null,
            )
        }
        return ProtectionSosStaleOutcome(
            action = ProtectionSosStaleAction.pending,
            state = current.copy(candidateFirstAt = now, candidatePushes = 1, lastPushAt = now),
            sendStop = sendStop,
            openPrompt = openPrompt,
            decideAt = maxOf(now, deliveredAt) + decideAfterMs,
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
                closePrompt = state.promptDeadlineAt != null,
            )
        }
        return resolveDecision(state, now)
    }

    /**
     * F17c: no countdown burst followed: ambiguous. Ask the user (once: an
     * open prompt is never re-opened), unless the user already answered "No"
     * within [consentMs]: then the stop is written again.
     */
    private fun resolveDecision(
        state: ProtectionSosStaleGuardState,
        now: Long,
    ): ProtectionSosStaleOutcome {
        val decided = state.copy(
            lastFrameAt = state.lastPushAt ?: state.candidateFirstAt ?: state.lastFrameAt,
            linkDroppedSinceLastFrame = false,
            candidateFirstAt = null,
            candidatePushes = 0,
        )
        val consent = state.stopConfirmedAt
        if (state.promptDeadlineAt == null && consent != null && now - consent in 0..consentMs) {
            return ProtectionSosStaleOutcome(
                action = ProtectionSosStaleAction.stale,
                state = decided,
                sendStop = true,
            )
        }
        if (state.promptDeadlineAt != null) {
            return ProtectionSosStaleOutcome(ProtectionSosStaleAction.prompt, decided)
        }
        return ProtectionSosStaleOutcome(
            action = ProtectionSosStaleAction.prompt,
            state = decided.copy(promptDeadlineAt = now + promptMs, stopConfirmedAt = null),
            openPrompt = true,
        )
    }

    /**
     * F17c: the user's answer ([choice] `sendSos` / `stopTag`) or the native
     * timer (`timeout`). Only while a prompt is open. Send and the timeout
     * open the SOS and end the record; "No" writes the matching stop and keeps
     * the record (the TAG must still confirm). A "No" at or after the deadline
     * is the timeout: never a stop without a timely answer.
     */
    fun onAnswer(
        state: ProtectionSosStaleGuardState?,
        choice: String,
        now: Long,
    ): ProtectionSosStaleOutcome {
        val deadline = state?.promptDeadlineAt
            ?: return ProtectionSosStaleOutcome(ProtectionSosStaleAction.none, state)
        val sendSos = ProtectionSosStaleOutcome(
            action = ProtectionSosStaleAction.sosOpened,
            state = null,
            closePrompt = true,
            openSos = true,
            reason = if (choice == "sendSos") "prompt_send_sos" else "prompt_timeout",
        )
        return when (choice) {
            "sendSos" -> sendSos
            "timeout" -> if (now >= deadline) {
                sendSos
            } else {
                ProtectionSosStaleOutcome(ProtectionSosStaleAction.none, state)
            }
            "stopTag" -> if (now >= deadline) {
                sendSos
            } else {
                ProtectionSosStaleOutcome(
                    action = ProtectionSosStaleAction.stop,
                    state = state.copy(promptDeadlineAt = null, stopConfirmedAt = now),
                    sendStop = true,
                    closePrompt = true,
                    reason = "prompt_stop_tag",
                )
            }
            else -> ProtectionSosStaleOutcome(ProtectionSosStaleAction.none, state)
        }
    }

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
