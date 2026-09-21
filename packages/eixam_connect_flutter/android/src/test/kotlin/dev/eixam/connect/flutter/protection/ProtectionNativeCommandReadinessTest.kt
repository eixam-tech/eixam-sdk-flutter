package dev.eixam.connect.flutter.protection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtectionNativeCommandReadinessTest {
    @Test
    fun `connected stale GATT is preparing and never command ready`() {
        val readiness = ProtectionNativeCommandReadiness(
            owner = true,
            gattConnected = true,
            serviceReady = false,
            cmdEa04Ready = false,
            identityReady = false,
            queueHealthy = true,
        )

        assertFalse(readiness.ready)
        assertEquals("serviceDiscovered", readiness.falsePredicate)
    }

    @Test
    fun `EA04 discovery makes command ready before notification subscriptions complete`() {
        val readiness = ProtectionNativeCommandReadiness(
            owner = true,
            gattConnected = true,
            serviceReady = true,
            cmdEa04Ready = true,
            identityReady = true,
            queueHealthy = true,
        )

        assertTrue(readiness.ready)
        assertEquals(null, readiness.falsePredicate)
    }

    @Test
    fun `identity mismatch and missing EA04 fail closed`() {
        val mismatch = ProtectionNativeCommandReadiness(
            owner = true,
            gattConnected = true,
            serviceReady = true,
            cmdEa04Ready = true,
            identityReady = false,
            queueHealthy = true,
        )
        val missingEa04 = mismatch.copy(
            cmdEa04Ready = false,
            identityReady = true,
        )

        assertFalse(mismatch.ready)
        assertEquals("exactIdentityMatch", mismatch.falsePredicate)
        assertFalse(missingEa04.ready)
        assertEquals("ea04Present", missingEa04.falsePredicate)
    }

    @Test
    fun `queue failure invalidates and reconnect inputs restore readiness`() {
        val failed = ProtectionNativeCommandReadiness(
            owner = true,
            gattConnected = true,
            serviceReady = true,
            cmdEa04Ready = true,
            identityReady = true,
            queueHealthy = false,
        )

        assertFalse(failed.ready)
        assertEquals("queueHealthy", failed.falsePredicate)
        assertTrue(failed.copy(queueHealthy = true).ready)
    }
}
