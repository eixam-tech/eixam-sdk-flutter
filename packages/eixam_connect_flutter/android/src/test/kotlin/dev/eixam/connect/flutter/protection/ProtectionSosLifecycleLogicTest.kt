package dev.eixam.connect.flutter.protection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtectionSosLifecycleLogicTest {
    @Test
    fun `preConfirm does not promote to active on repeated mesh packet`() {
        val stateAfterFirstPacket =
            ProtectionSosLifecycleLogic.onMeshPacket(ProtectionSosLifecycleState.idle)
        val stateAfterSecondPacket =
            ProtectionSosLifecycleLogic.onMeshPacket(stateAfterFirstPacket)

        assertEquals(ProtectionSosLifecycleState.preConfirmSeen, stateAfterFirstPacket)
        assertEquals(ProtectionSosLifecycleState.preConfirmSeen, stateAfterSecondPacket)
    }

    @Test
    fun `countdown promotes preConfirm to active create state`() {
        val nextState =
            ProtectionSosLifecycleLogic.onCountdownElapsed(
                ProtectionSosLifecycleState.preConfirmSeen,
            )

        assertEquals(ProtectionSosLifecycleState.createPending, nextState)
    }

    @Test
    fun `active create state ignores repeated mesh packet`() {
        val nextState =
            ProtectionSosLifecycleLogic.onMeshPacket(
                ProtectionSosLifecycleState.createPending,
            )

        assertEquals(ProtectionSosLifecycleState.createPending, nextState)
    }

    @Test
    fun `cancel pending state ignores repeated mesh packet`() {
        val nextState =
            ProtectionSosLifecycleLogic.onMeshPacket(
                ProtectionSosLifecycleState.cancelPending,
            )

        assertEquals(ProtectionSosLifecycleState.cancelPending, nextState)
    }

    @Test
    fun `closing preConfirm does not request backend cancel`() {
        val outcome =
            ProtectionSosLifecycleLogic.onClosePacket(
                ProtectionSosLifecycleState.preConfirmSeen,
            )

        assertEquals(ProtectionSosLifecycleState.cancelPending, outcome.nextState)
        assertFalse(outcome.shouldCancelBackend)
    }

    @Test
    fun `closing active cycle requests backend cancel`() {
        val outcome =
            ProtectionSosLifecycleLogic.onClosePacket(
                ProtectionSosLifecycleState.createPending,
            )

        assertEquals(ProtectionSosLifecycleState.cancelPending, outcome.nextState)
        assertTrue(outcome.shouldCancelBackend)
    }

    @Test
    fun `backend terminal close (0xE3) never requests backend cancel`() {
        val outcome =
            ProtectionSosLifecycleLogic.onClosePacket(
                ProtectionSosLifecycleState.createPending,
                backendTerminal = true,
            )

        assertEquals(ProtectionSosLifecycleState.cancelPending, outcome.nextState)
        assertFalse(outcome.shouldCancelBackend)
    }

    @Test
    fun `native hand-off identity is unique per SOS even with a recycled frame key`() {
        val first = ProtectionSosLifecycleLogic.nativeHandoffCycleKey("sos:7:3", 1_000L)
        val sameCycle = ProtectionSosLifecycleLogic.nativeHandoffCycleKey("sos:7:3", 1_000L)
        val nextSos = ProtectionSosLifecycleLogic.nativeHandoffCycleKey("sos:7:3", 95_000L)

        assertEquals("sos:7:3@1000", first)
        assertEquals(first, sameCycle)
        assertTrue(first != nextSos)
    }

    @Test
    fun `native hand-off identity without a cycle start keeps the frame key`() {
        assertEquals("sos:7:3", ProtectionSosLifecycleLogic.nativeHandoffCycleKey("sos:7:3", 0L))
        assertEquals(null, ProtectionSosLifecycleLogic.nativeHandoffCycleKey(" ", 1_000L))
    }
}
