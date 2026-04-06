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
}
