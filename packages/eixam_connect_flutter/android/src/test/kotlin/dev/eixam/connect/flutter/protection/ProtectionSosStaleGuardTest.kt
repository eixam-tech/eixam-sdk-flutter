package dev.eixam.connect.flutter.protection

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * F17b (2026-11-15): the SDK closed an SOS (app cancel / portal resolve) but the
 * stop never reached the TAG, which kept sending its SOS frames. Firmware:
 * every push is sent twice (SOS + TEL notify, ms apart); COUNTDOWN pushes at
 * 0/500/1000/1500 ms; ACTIVE pushes once per retry (2, 8, 20, 60 s), and the
 * 60 s TEL barrier can be followed by an immediate retry.
 */
class ProtectionSosStaleGuardTest {
    private val guard = ProtectionSosStaleGuard
    private val t0 = 1_000_000L
    private val node = 0x1234

    private fun armedConnected(
        terminal: ProtectionSosStaleTerminal = ProtectionSosStaleTerminal.cancel,
    ): ProtectionSosStaleGuardState =
        guard.arm(terminal = terminal, nodeId = node, now = t0, connected = true)

    private fun armedDisconnected(
        terminal: ProtectionSosStaleTerminal = ProtectionSosStaleTerminal.cancel,
    ): ProtectionSosStaleGuardState =
        guard.arm(terminal = terminal, nodeId = node, now = t0, connected = false)

    /** Feeds frames (absolute times) and decides 2 s after the last window opened. */
    private class Run(var state: ProtectionSosStaleGuardState?) {
        val outcomes = mutableListOf<ProtectionSosStaleOutcome>()
        var pendingDecideAt: Long? = null

        fun frame(at: Long, nodeId: Int? = 0x1234): ProtectionSosStaleOutcome {
            val decideAt = pendingDecideAt
            if (decideAt != null && at >= decideAt) decide(decideAt)
            val outcome = ProtectionSosStaleGuard.onFrame(state, nodeId, at)
            outcomes += outcome
            state = outcome.state
            if (outcome.decideAt != null) pendingDecideAt = outcome.decideAt
            if (outcome.state == null) pendingDecideAt = null
            return outcome
        }

        fun decide(at: Long): ProtectionSosStaleOutcome? {
            val current = state ?: return null
            val outcome = ProtectionSosStaleGuard.onDecide(current, at)
            outcomes += outcome
            state = outcome.state
            pendingDecideAt = null
            return outcome
        }

        fun finish(at: Long) {
            pendingDecideAt?.let { decide(maxOf(it, at)) }
        }

        val newSos get() = outcomes.any { it.action == ProtectionSosStaleAction.newSos }
        val stops get() = outcomes.count { it.sendStop }
        val prompts get() = outcomes.count { it.openPrompt }
        val passedToLifecycle get() = outcomes.count { it.passesToLifecycle }
    }

    // --- C1 / C2: classification -------------------------------------------

    @Test
    fun `duplicate copies 5 ms apart are one ambiguous push - a prompt, never a stop or a new SOS`() {
        val run = Run(armedConnected())
        run.frame(t0 + 20_000L)
        assertEquals(ProtectionSosStaleAction.duplicate, run.frame(t0 + 20_005L).action)
        run.finish(t0 + 22_000L)
        assertFalse(run.newSos)
        assertEquals("F17c: never stopped without the user", 0, run.stops)
        assertEquals(1, run.prompts)
        assertEquals(ProtectionSosStaleAction.prompt, run.outcomes.last().action)
        assertEquals(t0 + 22_000L + ProtectionSosStaleGuard.promptMs, run.state!!.promptDeadlineAt)
        assertEquals("frames swallowed, never to the lifecycle or Dart", 0, run.passedToLifecycle)
    }

    @Test
    fun `barrier plus retry pair 800 ms apart, each duplicated, is ambiguous`() {
        val run = Run(armedConnected())
        val at = t0 + 60_000L
        run.frame(at)
        run.frame(at + 5L)
        run.frame(at + 800L)
        run.frame(at + 805L)
        run.finish(at + 2_000L)
        assertFalse(run.newSos)
        assertEquals(0, run.stops)
        assertEquals(1, run.prompts)
    }

    @Test
    fun `real countdown pushes 0-500-1000-1500, each duplicated, is a new SOS from the first push`() {
        val run = Run(armedConnected())
        val at = t0 + 60_000L
        var newSos: ProtectionSosStaleOutcome? = null
        for (offset in listOf(0L, 5L, 500L, 505L, 1_000L)) {
            val outcome = run.frame(at + offset)
            if (outcome.action == ProtectionSosStaleAction.newSos) newSos = outcome
        }
        assertNotNull(newSos)
        assertEquals(at, newSos!!.startedAt)
        assertNull("guard ended", run.state)
        assertEquals(0, run.stops)
    }

    @Test
    fun `a push after the window resolves the old candidate as ambiguous and opens a new one`() {
        val run = Run(armedConnected())
        val at = t0 + 20_000L
        run.frame(at)
        val later = ProtectionSosStaleGuard.onFrame(run.state, node, at + 1_800L)
        assertEquals(ProtectionSosStaleAction.pending, later.action)
        assertFalse("never stopped without the user", later.sendStop)
        assertTrue("old candidate asks the user", later.openPrompt)
        assertEquals(at + 1_800L, later.state!!.candidateFirstAt)
    }

    // --- A1 and reconnect --------------------------------------------------

    @Test
    fun `cancel while disconnected then reconnect with ACTIVE frames prompts once, No writes the cancel stop`() {
        val armed = armedDisconnected()
        assertTrue("disconnected at arm counts as a link drop", armed.linkDroppedSinceLastFrame)
        assertFalse(guard.shouldSendStopOnArm(lastSosFrameAt = t0 - 5_000L, connected = false, now = t0))
        val run = Run(guard.onReconnected(armed, t0 + 300_000L))
        run.frame(t0 + 301_000L)
        run.frame(t0 + 301_004L)
        run.finish(t0 + 303_000L)
        run.frame(t0 + 310_000L)
        run.finish(t0 + 312_000L)
        assertFalse(run.newSos)
        assertEquals(0, run.stops)
        assertEquals("one prompt at a time", 1, run.prompts)
        val no = guard.onAnswer(run.state, "stopTag", t0 + 315_000L)
        assertEquals(ProtectionSosStaleAction.stop, no.action)
        assertTrue(no.sendStop && no.closePrompt && !no.openSos)
        assertArrayEquals(byteArrayOf(0x04), run.state!!.terminal.stopPayload)
        assertEquals("SOS CANCEL", run.state!!.terminal.commandLabel)
    }

    @Test
    fun `resolve prompts with its kind and No writes the resolve stop`() {
        val run = Run(armedDisconnected(ProtectionSosStaleTerminal.resolve))
        run.frame(t0 + 61_000L)
        run.finish(t0 + 63_000L)
        assertEquals(0, run.stops)
        assertEquals(1, run.prompts)
        assertTrue(guard.onAnswer(run.state, "stopTag", t0 + 64_000L).sendStop)
        assertArrayEquals(byteArrayOf(0x07), run.state!!.terminal.stopPayload)
        assertEquals("SOS ACK", run.state!!.terminal.commandLabel)
    }

    @Test
    fun `reconnect with a COUNTDOWN burst is a new SOS`() {
        val run = Run(guard.onReconnected(armedDisconnected(), t0 + 300_000L))
        listOf(0L, 3L, 500L, 503L, 1_000L).forEach { run.frame(t0 + 301_000L + it) }
        assertTrue(run.newSos)
        assertEquals(0, run.stops)
    }

    @Test
    fun `reconnect then silence over 90 s - the next single frame is still ambiguous (F17c, no gap end)`() {
        val reconnectAt = t0 + 120_000L
        val reconnected = guard.onReconnected(armedDisconnected(), reconnectAt)
        assertFalse(reconnected.linkDroppedSinceLastFrame)
        assertEquals(reconnectAt, reconnected.lastFrameAt)
        val outcome = guard.onFrame(reconnected, node, reconnectAt + 95_000L)
        assertEquals(ProtectionSosStaleAction.pending, outcome.action)
        assertFalse(outcome.passesToLifecycle)
    }

    @Test
    fun `reconnect writes no stop and the first single frame after it asks the user`() {
        val reconnectAt = t0 + 120_000L
        val run = Run(guard.onReconnected(armedDisconnected(), reconnectAt))
        assertEquals("nothing before a frame", 0, run.stops)
        run.frame(reconnectAt + 40_000L)
        run.finish(reconnectAt + 42_000L)
        assertEquals(0, run.stops)
        assertEquals(1, run.prompts)
    }

    @Test
    fun `a link drop keeps the guard across a long gap (A1)`() {
        val dropped = guard.onLinkDropped(armedConnected())
        assertEquals(
            ProtectionSosStaleAction.pending,
            guard.onFrame(dropped, node, t0 + 240_000L).action,
        )
    }

    // --- H3: gap clock starts at arm ----------------------------------------

    @Test
    fun `the gap clock starts at arm time, not at the last frame before it`() {
        val armed = armedConnected()
        assertEquals(t0, armed.lastFrameAt)
        // A retry 60 s after arming is still within the gap: the closed SOS.
        assertEquals(ProtectionSosStaleAction.pending, guard.onFrame(armed, node, t0 + 60_000L).action)
        // The arm-time stop decision still uses the last frame seen before arming.
        assertTrue(guard.shouldSendStopOnArm(lastSosFrameAt = t0 - 30_000L, connected = true, now = t0))
        assertFalse(guard.shouldSendStopOnArm(lastSosFrameAt = t0 - 200_000L, connected = true, now = t0))
    }

    // --- end of the guard ---------------------------------------------------

    @Test
    fun `TAG close frame ends the guard so a later press is admitted`() {
        assertNull(guard.onTagClose(armedConnected()))
        assertEquals(ProtectionSosStaleAction.notArmed, guard.onFrame(null, node, t0 + 70_000L).action)
    }

    @Test
    fun `no link drop and a gap over 90 s keeps the record (F17c)`() {
        assertEquals(ProtectionSosStaleAction.pending, guard.onFrame(armedConnected(), node, t0 + 120_000L).action)
    }

    @Test
    fun `the record has no time cap (F17c)`() {
        val outcome = guard.onFrame(armedDisconnected(), node, t0 + 2L * 86_400_000L)
        assertEquals(ProtectionSosStaleAction.pending, outcome.action)
    }

    @Test
    fun `an owed stop is re-attempted until written, then a retry asks again`() {
        val run = Run(armedDisconnected())
        run.frame(t0 + 30_000L)
        run.finish(t0 + 32_000L)
        val no = guard.onAnswer(run.state, "stopTag", t0 + 33_000L)
        assertTrue(no.state!!.stopOwed)
        val owed = Run(guard.onStopWritten(no.state, success = false))
        owed.frame(t0 + 40_000L)
        owed.finish(t0 + 42_000L)
        assertEquals("failed write: still owed, re-attempted", 1, owed.stops)
        assertEquals(0, owed.prompts)
        assertEquals("no prompt open: a timeout is impossible", ProtectionSosStaleAction.none,
            guard.onAnswer(owed.state, "timeout", t0 + 90_000L).action)
        val written = Run(guard.onStopWritten(owed.state, success = true))
        assertFalse(written.state!!.stopOwed)
        written.frame(t0 + 100_000L)
        written.finish(t0 + 102_000L)
        assertEquals(0, written.stops)
        assertEquals("written: the next retry asks again", 1, written.prompts)
    }

    @Test
    fun `session change disarms the guard`() {
        assertNull(guard.onSessionChanged(armedConnected()))
    }

    // --- M4: other TAG ------------------------------------------------------

    @Test
    fun `frames of another node are ignored and never disarm or classify`() {
        val armed = armedConnected()
        val outcome = guard.onFrame(armed, 0x9999, t0 + 20_000L)
        assertEquals(ProtectionSosStaleAction.ignored, outcome.action)
        assertEquals(armed, outcome.state)
        assertEquals(
            "unknown frame node: classified",
            ProtectionSosStaleAction.pending,
            guard.onFrame(armed, null, t0 + 20_000L).action,
        )
    }

    // --- M2 / M5: arming and the SDK close of the native cycle ---------------

    @Test
    fun `arms only for a handed-over SOS`() {
        assertTrue(
            guard.shouldArm(
                ProtectionSosStaleTerminal.cancel,
                ProtectionSosLifecycleState.createPending,
                hasUnclaimedNativeCreate = false,
            ),
        )
        assertTrue(
            "F17c: a running countdown's cancel is an unconfirmed stop too",
            guard.shouldArm(
                ProtectionSosStaleTerminal.cancel,
                ProtectionSosLifecycleState.preConfirmSeen,
                hasUnclaimedNativeCreate = false,
            ),
        )
        assertFalse(
            "never while the SDK has not claimed the create",
            guard.shouldArm(
                ProtectionSosStaleTerminal.cancel,
                ProtectionSosLifecycleState.createPending,
                hasUnclaimedNativeCreate = true,
            ),
        )
        assertFalse(
            "idle (the TAG closed it first): nothing to stop",
            guard.shouldArm(
                ProtectionSosStaleTerminal.resolve,
                ProtectionSosLifecycleState.idle,
                hasUnclaimedNativeCreate = false,
            ),
        )
        assertFalse(
            "no terminal (activation failed)",
            guard.shouldArm(null, ProtectionSosLifecycleState.createPending, hasUnclaimedNativeCreate = false),
        )
    }

    /** F17c-cdc: app cancel 8 s into the native countdown, TAG out of range. */
    @Test
    fun `an sdk cancel ends the running countdown and arms the record like any stop`() {
        val countdown = ProtectionSosLifecycleState.preConfirmSeen
        val cancel = ProtectionSosStaleTerminal.cancel
        assertTrue(guard.cancelsRunningCountdown(cancel, countdown, false, t0, t0 + 8_000L))
        assertTrue(guard.cancelsRunningCountdown(cancel, countdown, false, t0, t0 + 1_000L))
        assertTrue(
            "F17c: one rule; a cancelled countdown arms the record",
            guard.shouldArm(cancel, countdown, false, null, t0 + 8_000L),
        )
        assertFalse(
            "only an SDK cancel ends a countdown",
            guard.cancelsRunningCountdown(ProtectionSosStaleTerminal.resolve, countdown, false, t0, t0 + 8_000L),
        )
        assertFalse(
            "never with an unclaimed native create",
            guard.cancelsRunningCountdown(cancel, countdown, true, t0, t0 + 8_000L),
        )
        assertFalse(
            "start unknown (or another TAG's countdown)",
            guard.cancelsRunningCountdown(cancel, countdown, false, null, t0 + 8_000L),
        )
        assertFalse(
            "a countdown started after the cancel is a newer SOS",
            guard.cancelsRunningCountdown(cancel, countdown, false, t0 + 9_000L, t0 + 8_000L),
        )
    }

    @Test
    fun `an SDK close always closes a handed-over cycle so rehydrate never re-creates it`() {
        val afterClose = ProtectionSosLifecycleLogic.onSdkClose(
            ProtectionSosLifecycleState.createPending,
            hasUnclaimedNativeCreate = false,
        )
        assertEquals(ProtectionSosLifecycleState.idle, afterClose)
        assertFalse(ProtectionSosLifecycleLogic.shouldRequeueCreateOnRehydrate(afterClose))
        assertTrue(
            ProtectionSosLifecycleLogic.shouldRequeueCreateOnRehydrate(
                ProtectionSosLifecycleState.createPending,
            ),
        )
    }

    @Test
    fun `an SDK close never cancels a running countdown or an unclaimed create`() {
        assertEquals(
            ProtectionSosLifecycleState.preConfirmSeen,
            ProtectionSosLifecycleLogic.onSdkClose(
                ProtectionSosLifecycleState.preConfirmSeen,
                hasUnclaimedNativeCreate = false,
            ),
        )
        assertEquals(
            ProtectionSosLifecycleState.createPending,
            ProtectionSosLifecycleLogic.onSdkClose(
                ProtectionSosLifecycleState.createPending,
                hasUnclaimedNativeCreate = true,
            ),
        )
    }

    @Test
    fun `guard state survives process death through its persisted form`() {
        val armed = armedDisconnected(ProtectionSosStaleTerminal.resolve)
        val restored = ProtectionSosStaleGuardState.fromPersisted(armed.toPersisted())
        assertEquals(armed, restored)
    }

    /** A 12 B own-TAG SOS frame (nodeId u32 LE first), as the TAG pushes it. */
    private fun sosFrame(nodeId: Int): List<Int> =
        listOf(nodeId and 0xFF, (nodeId shr 8) and 0xFF, (nodeId shr 16) and 0xFF, (nodeId shr 24) and 0xFF) +
            listOf(0x48, 0xCD, 0x1B, 0x34, 0x44, 0x28, 0x00, 0xC0)

    /** The TAG's 6 B close frame (firmware 07 §1.2), closed with the SOS fired (sub 0x02). */
    private fun closeFrame(opcode: Int, nodeId: Int): List<Int> =
        listOf(opcode, 0x02, nodeId and 0xFF, (nodeId shr 8) and 0xFF, (nodeId shr 16) and 0xFF, (nodeId shr 24) and 0xFF)

    /**
     * F17c: the scenario fixture shared with the iOS store and the Dart contract
     * test, replayed through the production decision code of the runtime owner
     * ([ProtectionSosNativeDecision]: frame classification, guard, native
     * lifecycle step, SDK-terminal arming, prompt send) on real frame bytes, and
     * the forwarded-frame parser/guard Dart's frames go through. Only side
     * effects (persistence, timers, TAG writes) are left out.
     */
    @Test
    fun `shared stale guard scenarios replay identically`() {
        val fixture = listOf(
            "../test/fixtures/stale_sos_guard_scenarios.txt",
            "test/fixtures/stale_sos_guard_scenarios.txt",
            "packages/eixam_connect_flutter/test/fixtures/stale_sos_guard_scenarios.txt",
        ).map { java.io.File(it) }.firstOrNull { it.exists() }
        assertNotNull("shared fixture not found from ${java.io.File(".").absolutePath}", fixture)
        var state: ProtectionSosStaleGuardState? = null
        var observed: ProtectionSosObservedCycle? = null
        var lifecycle = ProtectionSosLifecycleState.idle
        var lifecycleNodeId: Int? = null
        var unclaimed = false
        var countdownStartedAt: Long? = null
        var name = ""
        var steps = 0
        var dartFrames = 0
        var nativeFrames = 0
        var phase2Terminals = 0
        val failures = mutableListOf<String>()
        val base = 5_000_000L
        for (raw in fixture!!.readLines()) {
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("#")) continue
            if (line.startsWith("scenario ")) {
                name = line.removePrefix("scenario ")
                state = null
                observed = null
                lifecycle = ProtectionSosLifecycleState.idle
                lifecycleNodeId = null
                unclaimed = false
                countdownStartedAt = null
                continue
            }
            val (eventPart, expectPart) = line.split(" => ")
            val event = eventPart.split(" ")
            val expect = expectPart.split(" ")
            val t = base + event[0].toLong()
            val args = event.drop(2).mapNotNull { token ->
                token.split("=", limit = 2).takeIf { it.size == 2 }?.let { it[0] to it[1] }
            }.toMap()
            val want = expect.drop(1).mapNotNull { token ->
                token.split("=", limit = 2).takeIf { it.size == 2 }?.let { it[0] to it[1] }
            }.toMap()
            val node = args["node"]?.toInt() ?: 7
            val label = "$name @${event[0]} ${event[1]}"
            var outcome: ProtectionSosStaleOutcome? = null
            try {
            when (event[1]) {
                "seen" -> when (args["source"]) {
                    "native" -> {
                        lifecycle = ProtectionSosLifecycleState.createPending
                        lifecycleNodeId = node
                    }
                    "native_unclaimed" -> {
                        lifecycle = ProtectionSosLifecycleState.createPending
                        lifecycleNodeId = node
                        unclaimed = true
                    }
                    "countdown" -> {
                        lifecycle = ProtectionSosLifecycleState.preConfirmSeen
                        lifecycleNodeId = node
                        countdownStartedAt = t - args["age"]!!.toLong()
                    }
                    "dart" -> {
                        val age = args["age"]!!.toLong()
                        val sos = ProtectionSosForwardedFrame.parse(sosFrame(node))!!
                        observed = guard.onForwardedFrame(null, observed, sos, t - age).observed
                        observed = guard.onForwardedFrame(null, observed, sos, t - 1).observed
                    }
                    else -> Unit
                }
                "terminal" -> {
                    val terminal = ProtectionSosStaleTerminal.fromWire(args["kind"])!!
                    val step = ProtectionSosNativeDecision.onSdkTerminal(
                        terminal = terminal,
                        lifecycle = lifecycle,
                        lifecycleNodeId = lifecycleNodeId,
                        terminalNodeId = node,
                        hasUnclaimedNativeCreate = unclaimed,
                        countdownStartedAt = countdownStartedAt,
                        observed = observed,
                        now = t,
                        issuedAt = args["issued"]?.let { base + it.toLong() },
                    )
                    if (args["issued"] != null) {
                        phase2Terminals++
                    }
                    if (step.nextLifecycle != lifecycle) {
                        countdownStartedAt = null
                    }
                    lifecycle = step.nextLifecycle
                    if (step.arm) {
                        state = guard.arm(
                            terminal,
                            node,
                            t,
                            connected = args["connected"] == "true",
                        )
                        observed = null
                    }
                }
                "frame" -> if (args["source"] == "dart") {
                    // t is Dart's receivedAtMs; delivered the native clock.
                    val delivered = args["delivered"]?.let { base + it.toLong() } ?: t
                    val decision = guard.onForwardedFrame(
                        state,
                        observed,
                        ProtectionSosForwardedFrame.parse(sosFrame(node))!!,
                        delivered,
                        receivedAt = t,
                    )
                    outcome = decision.outcome
                    observed = decision.observed
                    state = outcome.state
                    val wantVerdict = when (expect[0]) {
                        "pass" -> ProtectionOwnTagSosVerdict.proceed
                        "newSos" -> ProtectionOwnTagSosVerdict.newSos
                        else -> ProtectionOwnTagSosVerdict.suppress
                    }
                    assertEquals("$label: dart verdict", wantVerdict, decision.verdict)
                    dartFrames++
                } else {
                    val step = ProtectionSosNativeDecision.onSosFrame(state, lifecycle, sosFrame(node), t)
                    outcome = step.outcome
                    state = outcome.state
                    step.countdownObservedAt?.let {
                        countdownStartedAt = it
                        lifecycleNodeId = node
                    }
                    lifecycle = step.nextLifecycle
                    nativeFrames++
                }
                "decide" -> {
                    outcome = state?.let { guard.onDecide(it, t) }
                        ?: ProtectionSosStaleOutcome(ProtectionSosStaleAction.none, null)
                    state = outcome.state
                }
                "close" -> {
                    val opcode = when (args["code"]) {
                        "E2" -> 0xE2
                        "E3" -> 0xE3
                        else -> 0xE1
                    }
                    val bytes = closeFrame(opcode, node)
                    if (args["source"] == "dart") {
                        val decision = guard.onForwardedFrame(
                            state,
                            observed,
                            ProtectionSosForwardedFrame.parse(bytes)!!,
                            t,
                        )
                        assertEquals("$label: dart verdict", ProtectionOwnTagSosVerdict.proceed, decision.verdict)
                        state = decision.outcome.state
                        observed = decision.observed
                    } else {
                        // The owner's close path: the TAG's own close ends the guard and the cycle.
                        assertEquals("$label: close opcode", opcode, ProtectionSosNativeDecision.closeOpcode(bytes))
                        state = guard.onTagClose(state)
                        observed = null
                        lifecycle = ProtectionSosLifecycleState.idle
                        lifecycleNodeId = null
                        countdownStartedAt = null
                    }
                }
                "link_drop" -> state = state?.let {
                    if (args["source"] == "dart") guard.onForwardedLinkDropped(it) else guard.onLinkDropped(it)
                }
                "link_up" -> state = state?.let {
                    if (args["source"] == "dart") guard.onForwardedLinkUp(it, t) else guard.onReconnected(it, t)
                }
                "session" -> {
                    state = guard.onSessionChanged(state)
                    observed = null
                }
                "answer" -> {
                    outcome = guard.onAnswer(state, args["choice"]!!, t)
                    state = outcome.state
                    if (outcome.action == ProtectionSosStaleAction.sosOpened) {
                        val step = ProtectionSosNativeDecision.onPromptSos(lifecycle)
                        assertEquals("$label: create only when opened", step.opensNativeSos, step.queuesCreate)
                        assertTrue("$label: the SOS is opened natively", step.opensNativeSos)
                        lifecycle = ProtectionSosLifecycleState.createPending
                    }
                }
                "stop_written" -> state = guard.onStopWritten(state, args["ok"] == "true")
                "sdk_open" -> state = null
                else -> throw AssertionError("$name: unknown event ${event[1]}")
            }
            steps++
            if (expect[0] != "-") {
                val got = when (outcome?.action) {
                    ProtectionSosStaleAction.notArmed,
                    ProtectionSosStaleAction.ignored,
                    ProtectionSosStaleAction.disarmed,
                    -> "pass"
                    else -> outcome?.action?.name ?: "-"
                }
                assertEquals("$label: action", expect[0], got)
                if (event[1] == "frame" && args["source"] != "dart" && expect[0] == "pass") {
                    // F17c M-a: a native frame that passes reaches the native
                    // cycle, which runs after it (same check as Swift).
                    assertTrue(
                        "$label: passed but the native lifecycle is idle",
                        lifecycle != ProtectionSosLifecycleState.idle,
                    )
                }
            }
            val stop = if (outcome?.sendStop == true) state?.terminal?.wire ?: "?" else "none"
            assertEquals("$label: stop", want["stop"] ?: "none", stop)
            assertEquals("$label: opened", want["opened"] == "true", outcome?.openPrompt == true)
            want["kind"]?.let { assertEquals("$label: kind", it, state?.terminal?.wire) }
            want["prompt"]?.let {
                assertEquals("$label: prompt", it, if (state?.promptDeadlineAt != null) "open" else "closed")
            }
            if (outcome?.action == ProtectionSosStaleAction.sosOpened) {
                assertTrue("$label: the SOS is opened", outcome.openSos)
            }
            want["countdown"]?.let {
                val running = countdownStartedAt.takeIf { lifecycle == ProtectionSosLifecycleState.preConfirmSeen }
                assertEquals("$label: native countdown start", base + it.toLong(), running)
            }
            want["owed"]?.let { assertEquals("$label: owed", it == "true", state?.stopOwed == true) }
            want["armed"]?.let { assertEquals("$label: armed", it == "true", state != null) }
            want["cycle"]?.let {
                assertEquals(
                    "$label: native cycle",
                    it,
                    if (lifecycle == ProtectionSosLifecycleState.idle) "idle" else "running",
                )
            }
            } catch (failure: AssertionError) {
                // Every failing step is reported, not only the first one.
                failures.add(failure.message ?: label)
            }
        }
        assertTrue("scenario failures:\n" + failures.joinToString("\n"), failures.isEmpty())
        assertTrue("fixture replayed ($steps steps)", steps > 100)
        assertTrue("dart frames replayed ($dartFrames)", dartFrames > 20)
        assertTrue("native frames replayed ($nativeFrames)", nativeFrames > 20)
        assertTrue("stops with an issue time replayed ($phase2Terminals)", phase2Terminals >= 4)
    }

    /** F17c M2: "Send SOS" / the timeout queue a create only when native opened the SOS. */
    @Test
    fun `prompt send queues a create only when native opens the SOS`() {
        val idle = ProtectionSosNativeDecision.onPromptSos(ProtectionSosLifecycleState.idle)
        assertTrue(idle.opensNativeSos)
        assertTrue(idle.queuesCreate)
        for (running in listOf(
            ProtectionSosLifecycleState.preConfirmSeen,
            ProtectionSosLifecycleState.createPending,
            ProtectionSosLifecycleState.cancelPending,
        )) {
            val step = ProtectionSosNativeDecision.onPromptSos(running)
            assertFalse("$running: not opened", step.opensNativeSos)
            assertFalse("$running: no create, no active notification", step.queuesCreate)
        }
    }

    /** F17c L2: a decision timer that fires early decides nothing and is rescheduled. */
    @Test
    fun `an early decide is rescheduled at exactly 2 s after the first push`() {
        val armed = armedDisconnected()
        val pending = guard.onFrame(armed, node, t0 + 10_000).state!!
        val early = guard.onDecide(pending, t0 + 11_999)
        assertEquals(ProtectionSosStaleAction.none, early.action)
        assertEquals(t0 + 12_000, early.decideAt)
        assertEquals(ProtectionSosStaleAction.prompt, guard.onDecide(pending, t0 + 12_000).action)
    }

    @Test
    fun `forwarded frames are parsed like the native frame path`() {
        val active = listOf(0x34, 0x12, 0x00, 0x00, 0x48, 0xCD, 0x1B, 0x34, 0x44, 0x28, 0x00, 0xC0)
        assertEquals(
            ProtectionSosForwardedFrame(close = false, nodeId = 0x1234),
            ProtectionSosForwardedFrame.parse(active),
        )
        assertEquals(
            ProtectionSosForwardedFrame(close = true, nodeId = 0x1234),
            ProtectionSosForwardedFrame.parse(listOf(0xE1, 0x02, 0x34, 0x12, 0x00, 0x00)),
        )
        assertEquals(
            ProtectionSosForwardedFrame(close = true, nodeId = 0x1234),
            ProtectionSosForwardedFrame.parse(listOf(0xE3, 0x01, 0x34, 0x12, 0x00, 0x00)),
        )
        assertNull(ProtectionSosForwardedFrame.parse(listOf(0xE1, 0x09, 0x34, 0x12, 0x00, 0x00)))
        assertNull(ProtectionSosForwardedFrame.parse(listOf(0x01, 0x02, 0x03)))
    }

    /** F17c C1: no guard means every Dart frame proceeds at once (never waits for a decision). */
    @Test
    fun `without a guard every forwarded frame proceeds immediately`() {
        var observed: ProtectionSosObservedCycle? = null
        for (i in 0 until 4) {
            val decision = guard.onForwardedFrame(
                null,
                observed,
                ProtectionSosForwardedFrame(close = false, nodeId = node),
                t0 + i * 500L,
            )
            assertEquals(ProtectionOwnTagSosVerdict.proceed, decision.verdict)
            assertNull(decision.outcome.decideAt)
            observed = decision.observed
        }
        assertEquals(t0, observed!!.firstSeenAt)
    }

    /** F17c (Android foreground, 2026-11-16): `NATIVE_SOS_STALE_GUARD_NOT_ARMED lifecycle=idle`. */
    @Test
    fun `an sos seen only through dart arms the guard on the sdk terminal`() {
        var observed: ProtectionSosObservedCycle? = null
        val sos = ProtectionSosForwardedFrame(close = false, nodeId = node)
        observed = guard.onForwardedFrame(null, observed, sos, t0).observed
        observed = guard.onForwardedFrame(null, observed, sos, t0 + 20_000L).observed
        assertTrue(
            guard.shouldArm(
                ProtectionSosStaleTerminal.cancel,
                ProtectionSosLifecycleState.idle,
                hasUnclaimedNativeCreate = false,
                observed = observed,
                now = t0 + 30_000L,
            ),
        )
        assertFalse(
            "an unclaimed native create is never guarded",
            guard.shouldArm(
                ProtectionSosStaleTerminal.cancel,
                ProtectionSosLifecycleState.idle,
                hasUnclaimedNativeCreate = true,
                observed = observed,
                now = t0 + 30_000L,
            ),
        )
        assertFalse(
            "a cycle last seen long ago is not this SOS",
            guard.shouldArm(
                ProtectionSosStaleTerminal.cancel,
                ProtectionSosLifecycleState.idle,
                hasUnclaimedNativeCreate = false,
                observed = observed,
                now = t0 + 20_000L + ProtectionSosStaleGuard.observedRecentMs + 1,
            ),
        )
    }

    /** F17c: a Dart-seen SOS arms on its SDK terminal at any age (one rule, no 18 s threshold). */
    @Test
    fun `an sos seen only through dart arms at any age`() {
        val sos = ProtectionSosForwardedFrame(close = false, nodeId = node)
        val observed = guard.onForwardedFrame(null, null, sos, t0).observed
        assertTrue(
            guard.shouldArm(
                ProtectionSosStaleTerminal.cancel,
                ProtectionSosLifecycleState.idle,
                hasUnclaimedNativeCreate = false,
                observed = observed,
                now = t0 + 1_000L,
            ),
        )
    }

    @Test
    fun `the prompt timeout opens the SOS only at its deadline and the record survives process death`() {
        val run = Run(armedDisconnected())
        run.frame(t0 + 30_000L)
        run.finish(t0 + 32_000L)
        val deadline = run.state!!.promptDeadlineAt!!
        val restored = ProtectionSosStaleGuardState.fromPersisted(run.state!!.toPersisted())!!
        assertEquals(deadline, restored.promptDeadlineAt)
        assertEquals(ProtectionSosStaleAction.none, guard.onAnswer(restored, "timeout", deadline - 1).action)
        val timeout = guard.onAnswer(restored, "timeout", deadline)
        assertEquals(ProtectionSosStaleAction.sosOpened, timeout.action)
        assertTrue(timeout.openSos && timeout.closePrompt && !timeout.sendStop)
        assertNull(timeout.state)
    }

    @Test
    fun `send SOS opens the SOS and never writes a stop`() {
        val run = Run(armedDisconnected(ProtectionSosStaleTerminal.resolve))
        run.frame(t0 + 30_000L)
        run.finish(t0 + 32_000L)
        val send = guard.onAnswer(run.state, "sendSos", t0 + 33_000L)
        assertEquals(ProtectionSosStaleAction.sosOpened, send.action)
        assertTrue(send.openSos)
        assertFalse(send.sendStop)
        assertNull(send.state)
    }

    @Test
    fun `no answer is accepted without an open prompt`() {
        for (choice in listOf("sendSos", "stopTag", "timeout")) {
            val outcome = guard.onAnswer(armedConnected(), choice, t0 + 1_000L)
            assertEquals(ProtectionSosStaleAction.none, outcome.action)
            assertFalse(outcome.openSos || outcome.sendStop)
        }
    }
}
