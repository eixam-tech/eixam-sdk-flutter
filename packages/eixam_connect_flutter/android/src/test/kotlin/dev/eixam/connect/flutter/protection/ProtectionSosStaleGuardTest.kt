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
        val notices get() = outcomes.count { it.showNotice }
        val passedToLifecycle get() = outcomes.count { it.passesToLifecycle }
    }

    // --- C1 / C2: classification -------------------------------------------

    @Test
    fun `duplicate copies 5 ms apart are the closed SOS, never a new SOS`() {
        val run = Run(armedConnected())
        run.frame(t0 + 20_000L)
        assertEquals(ProtectionSosStaleAction.duplicate, run.frame(t0 + 20_005L).action)
        run.finish(t0 + 22_000L)
        assertFalse(run.newSos)
        assertEquals(1, run.stops)
        assertEquals(1, run.notices)
        assertEquals("frames swallowed, never to the lifecycle or Dart", 0, run.passedToLifecycle)
    }

    @Test
    fun `barrier plus retry pair 800 ms apart, each duplicated, is the closed SOS`() {
        val run = Run(armedConnected())
        val at = t0 + 60_000L
        run.frame(at)
        run.frame(at + 5L)
        run.frame(at + 800L)
        run.frame(at + 805L)
        run.finish(at + 2_000L)
        assertFalse(run.newSos)
        assertEquals(1, run.stops)
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
    fun `a push after the window resolves the old candidate as stale and opens a new one`() {
        val run = Run(armedConnected())
        val at = t0 + 20_000L
        run.frame(at)
        val later = ProtectionSosStaleGuard.onFrame(run.state, node, at + 1_800L)
        assertEquals(ProtectionSosStaleAction.pending, later.action)
        assertTrue("old candidate stopped", later.sendStop)
        assertEquals(at + 1_800L, later.state!!.candidateFirstAt)
    }

    // --- A1 and reconnect --------------------------------------------------

    @Test
    fun `cancel while disconnected then reconnect with ACTIVE frames sends cancel stop and notice`() {
        val armed = armedDisconnected()
        assertTrue("disconnected at arm counts as a link drop", armed.linkDroppedSinceLastFrame)
        assertFalse(guard.shouldSendStopOnArm(lastSosFrameAt = t0 - 5_000L, connected = false, now = t0))
        val run = Run(guard.onReconnected(armed, t0 + 300_000L))
        run.frame(t0 + 301_000L)
        run.frame(t0 + 301_004L)
        run.finish(t0 + 303_000L)
        run.frame(t0 + 362_000L)
        run.finish(t0 + 364_000L)
        assertFalse(run.newSos)
        assertEquals(2, run.stops)
        assertEquals("notice once per guard", 1, run.notices)
        assertArrayEquals(byteArrayOf(0x04), run.state!!.terminal.stopPayload)
        assertEquals("SOS CANCEL", run.state!!.terminal.commandLabel)
    }

    @Test
    fun `resolve sends the resolve stop`() {
        val run = Run(armedDisconnected(ProtectionSosStaleTerminal.resolve))
        run.frame(t0 + 61_000L)
        run.finish(t0 + 63_000L)
        assertEquals(1, run.stops)
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
    fun `reconnect then silence over 90 s admits the next single frame as a new SOS`() {
        val reconnectAt = t0 + 120_000L
        val reconnected = guard.onReconnected(armedDisconnected(), reconnectAt)
        assertFalse(reconnected.linkDroppedSinceLastFrame)
        assertEquals(reconnectAt, reconnected.lastFrameAt)
        val outcome = guard.onFrame(reconnected, node, reconnectAt + 95_000L)
        assertEquals(ProtectionSosStaleAction.disarmed, outcome.action)
        assertEquals("gap", outcome.reason)
        assertTrue(outcome.passesToLifecycle)
    }

    @Test
    fun `reconnect writes no stop and the first single frame after it gets the stop`() {
        val reconnectAt = t0 + 120_000L
        val run = Run(guard.onReconnected(armedDisconnected(), reconnectAt))
        assertEquals("nothing before a frame", 0, run.stops)
        run.frame(reconnectAt + 40_000L)
        run.finish(reconnectAt + 42_000L)
        assertEquals(1, run.stops)
        assertEquals(1, run.notices)
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
    fun `no link drop and a gap over 90 s ends the guard`() {
        val outcome = guard.onFrame(armedConnected(), node, t0 + 120_000L)
        assertEquals("gap", outcome.reason)
    }

    @Test
    fun `the guard ends after 10 minutes`() {
        val outcome = guard.onFrame(armedDisconnected(), node, t0 + ProtectionSosStaleGuard.capMs + 1L)
        assertEquals("cap", outcome.reason)
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
        assertFalse(
            "never on a running countdown",
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

    /**
     * F17c: the scenario fixture shared with the iOS store and the Dart contract
     * test. Frames of both paths (native GATT, Dart-forwarded) go through the
     * same classifier; the SDK terminal arms whenever the SOS was seen on any path.
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
        var name = ""
        var steps = 0
        var dartFrames = 0
        val base = 5_000_000L
        for (raw in fixture!!.readLines()) {
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("#")) continue
            if (line.startsWith("scenario ")) {
                name = line.removePrefix("scenario ")
                state = null
                observed = null
                lifecycle = ProtectionSosLifecycleState.idle
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
            when (event[1]) {
                "seen" -> when (args["source"]) {
                    "native" -> lifecycle = ProtectionSosLifecycleState.createPending
                    "dart" -> {
                        val age = args["age"]!!.toLong()
                        val sos = ProtectionSosForwardedFrame(close = false, nodeId = node)
                        observed = guard.onForwardedFrame(null, observed, sos, t - age).observed
                        observed = guard.onForwardedFrame(null, observed, sos, t - 1).observed
                    }
                    else -> Unit
                }
                "terminal" -> {
                    val terminal = ProtectionSosStaleTerminal.fromWire(args["kind"])!!
                    if (guard.shouldArm(terminal, lifecycle, false, observed, t)) {
                        state = guard.arm(terminal, node, t, connected = args["connected"] == "true")
                        observed = null
                    }
                    lifecycle = ProtectionSosLifecycleState.idle
                }
                "frame" -> if (args["source"] == "dart") {
                    val decision = guard.onForwardedFrame(
                        state,
                        observed,
                        ProtectionSosForwardedFrame(close = false, nodeId = node),
                        t,
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
                    outcome = guard.onFrame(state, node, t)
                    state = outcome.state
                }
                "decide" -> {
                    outcome = state?.let { guard.onDecide(it, t) }
                        ?: ProtectionSosStaleOutcome(ProtectionSosStaleAction.none, null)
                    state = outcome.state
                }
                "close" -> if (args["source"] == "dart") {
                    val decision = guard.onForwardedFrame(
                        state,
                        observed,
                        ProtectionSosForwardedFrame(close = true, nodeId = node),
                        t,
                    )
                    assertEquals("$label: dart verdict", ProtectionOwnTagSosVerdict.proceed, decision.verdict)
                    state = decision.outcome.state
                    observed = decision.observed
                } else {
                    state = guard.onTagClose(state)
                    observed = null
                }
                "link_drop" -> state = state?.let { guard.onLinkDropped(it) }
                "link_up" -> state = state?.let { guard.onReconnected(it, t) }
                "session" -> {
                    state = guard.onSessionChanged(state)
                    observed = null
                }
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
            }
            val stop = if (outcome?.sendStop == true) state?.terminal?.wire ?: "?" else "none"
            assertEquals("$label: stop", want["stop"] ?: "none", stop)
            assertEquals("$label: notice", want["notice"] == "true", outcome?.showNotice == true)
            want["armed"]?.let { assertEquals("$label: armed", it == "true", state != null) }
        }
        assertTrue("fixture replayed ($steps steps)", steps > 100)
        assertTrue("dart frames replayed ($dartFrames)", dartFrames > 20)
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
            "a cycle last seen beyond the cap is not this SOS",
            guard.shouldArm(
                ProtectionSosStaleTerminal.cancel,
                ProtectionSosLifecycleState.idle,
                hasUnclaimedNativeCreate = false,
                observed = observed,
                now = t0 + 20_000L + ProtectionSosStaleGuard.capMs + 1,
            ),
        )
    }
}
