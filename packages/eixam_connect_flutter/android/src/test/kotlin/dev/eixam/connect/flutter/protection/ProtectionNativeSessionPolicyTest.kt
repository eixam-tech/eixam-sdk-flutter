package dev.eixam.connect.flutter.protection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ProtectionNativeSessionPolicyTest {
    @Test
    fun `preparation failures are typed after discovery begins`() {
        val timeout = evaluateProtectionNativePreparationFailure(
            gattConnected = true,
            discoveryCompleted = false,
            serviceReady = false,
            ea04Ready = false,
            identityReady = false,
            queueHealthy = true,
            discoveryTimedOut = true,
        )
        val serviceAbsent = evaluateProtectionNativePreparationFailure(
            gattConnected = true,
            discoveryCompleted = true,
            serviceReady = false,
            ea04Ready = false,
            identityReady = true,
            queueHealthy = true,
            discoveryTimedOut = false,
        )
        val ea04Absent = evaluateProtectionNativePreparationFailure(
            gattConnected = true,
            discoveryCompleted = true,
            serviceReady = true,
            ea04Ready = false,
            identityReady = true,
            queueHealthy = true,
            discoveryTimedOut = false,
        )
        val identityMismatch = evaluateProtectionNativePreparationFailure(
            gattConnected = true,
            discoveryCompleted = true,
            serviceReady = true,
            ea04Ready = true,
            identityReady = false,
            queueHealthy = true,
            discoveryTimedOut = false,
        )
        val queueUnhealthy = evaluateProtectionNativePreparationFailure(
            gattConnected = true,
            discoveryCompleted = true,
            serviceReady = true,
            ea04Ready = true,
            identityReady = true,
            queueHealthy = false,
            discoveryTimedOut = false,
        )

        assertEquals(ProtectionNativePreparationFailure.discoveryTimeout, timeout)
        assertEquals(ProtectionNativePreparationFailure.serviceAbsent, serviceAbsent)
        assertEquals(ProtectionNativePreparationFailure.ea04Absent, ea04Absent)
        assertEquals(ProtectionNativePreparationFailure.identityMismatch, identityMismatch)
        assertEquals(ProtectionNativePreparationFailure.queueUnhealthy, queueUnhealthy)
    }

    @Test
    fun `complete preparation has no typed failure`() {
        val failure = evaluateProtectionNativePreparationFailure(
            gattConnected = true,
            discoveryCompleted = true,
            serviceReady = true,
            ea04Ready = true,
            identityReady = true,
            queueHealthy = true,
            discoveryTimedOut = false,
        )

        assertNull(failure)
    }

    @Test
    fun `successful SOS cancel preserves the persistent Protection transport`() {
        val action = protectionTransportActionAfterSuccessfulCommand("SOS CANCEL")

        assertEquals(
            ProtectionSuccessfulCommandTransportAction.keepAliveAfterSosTerminal,
            action,
        )
    }

    @Test
    fun `successful non-terminal command keeps the persistent Protection transport`() {
        val action = protectionTransportActionAfterSuccessfulCommand("SOS TRIGGER APP")

        assertEquals(ProtectionSuccessfulCommandTransportAction.keepAlive, action)
    }
}
