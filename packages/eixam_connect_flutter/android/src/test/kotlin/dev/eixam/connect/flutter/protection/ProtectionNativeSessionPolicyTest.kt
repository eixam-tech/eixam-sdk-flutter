package dev.eixam.connect.flutter.protection

import org.junit.Assert.assertEquals
import org.junit.Test

class ProtectionNativeSessionPolicyTest {
    @Test
    fun `connected stale session prepares then restarts on discovery timeout`() {
        val preparing = evaluateProtectionNativeSessionAction(
            gattConnected = true,
            serviceReady = false,
            ea04Ready = false,
            identityReady = false,
            queueHealthy = true,
            discoveryTimedOut = false,
        )
        val timedOut = evaluateProtectionNativeSessionAction(
            gattConnected = true,
            serviceReady = false,
            ea04Ready = false,
            identityReady = false,
            queueHealthy = true,
            discoveryTimedOut = true,
        )

        assertEquals(ProtectionNativeSessionAction.preparing, preparing)
        assertEquals(ProtectionNativeSessionAction.restart, timedOut)
    }

    @Test
    fun `only complete current session becomes ready`() {
        val ready = evaluateProtectionNativeSessionAction(
            gattConnected = true,
            serviceReady = true,
            ea04Ready = true,
            identityReady = true,
            queueHealthy = true,
            discoveryTimedOut = false,
        )

        assertEquals(ProtectionNativeSessionAction.ready, ready)
    }
}
