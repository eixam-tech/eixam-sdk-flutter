package dev.eixam.connect.flutter.protection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtectionNativeSosCancelPolicyTest {
    @Test
    fun `stale generation cannot cancel the next active incident`() {
        val decision = evaluate(
            pending = pending(canonicalIncidentId = "incident-n"),
            activeIncidentId = "incident-n-plus-1",
        )

        assertEquals(ProtectionNativeSosCancelOutcome.incidentMismatch, decision.outcome)
        assertFalse(decision.executeBackendCancel)
        assertEquals(0, executeAndCountBackendCancels(decision))
    }

    @Test
    fun `same generation exact incident match executes one cancel`() {
        val decision = evaluate(
            pending = pending(canonicalIncidentId = "incident-n"),
            activeIncidentId = "incident-n",
        )

        assertEquals(ProtectionNativeSosCancelOutcome.pendingAccepted, decision.outcome)
        assertTrue(decision.executeBackendCancel)
        assertEquals(1, executeAndCountBackendCancels(decision))
    }

    @Test
    fun `missing canonical incident never calls generic cancel`() {
        val decision = evaluate(
            pending = pending(canonicalIncidentId = null),
            activeIncidentId = "incident-n-plus-1",
        )

        assertEquals(ProtectionNativeSosCancelOutcome.noCanonicalTarget, decision.outcome)
        assertFalse(decision.executeBackendCancel)
        assertEquals(0, executeAndCountBackendCancels(decision))
    }

    @Test
    fun `legacy persisted count without structured record is stale after restart`() {
        val decision = evaluate(
            pending = null,
            activeIncidentId = "incident-n-plus-1",
        )

        assertEquals(ProtectionNativeSosCancelOutcome.pendingStaleRejected, decision.outcome)
        assertFalse(decision.executeBackendCancel)
        assertEquals("legacy_record_without_identity", decision.reason)
        assertEquals(0, executeAndCountBackendCancels(decision))
    }

    @Test
    fun `structured pending generation restored after restart is retired when terminal`() {
        val restoredPending = pending(canonicalIncidentId = "incident-n")

        val decision = evaluate(
            pending = restoredPending,
            activeIncidentId = null,
        )

        assertEquals(ProtectionNativeSosCancelOutcome.pendingStaleRejected, decision.outcome)
        assertEquals("backend_has_no_active_incident", decision.reason)
        assertEquals(0, executeAndCountBackendCancels(decision))
    }

    @Test
    fun `stale generation cannot mutate either of two later generations`() {
        val stale = pending(canonicalIncidentId = "incident-n")

        val next = evaluate(pending = stale, activeIncidentId = "incident-n-plus-1")
        val later = evaluate(pending = stale, activeIncidentId = "incident-n-plus-2")

        assertEquals(ProtectionNativeSosCancelOutcome.incidentMismatch, next.outcome)
        assertEquals(ProtectionNativeSosCancelOutcome.incidentMismatch, later.outcome)
        assertEquals(
            0,
            executeAndCountBackendCancels(next) + executeAndCountBackendCancels(later),
        )
    }

    @Test
    fun `terminal generation with no active incident retires without cancel`() {
        val decision = evaluate(
            pending = pending(canonicalIncidentId = "incident-n"),
            activeIncidentId = null,
        )

        assertEquals(ProtectionNativeSosCancelOutcome.pendingStaleRejected, decision.outcome)
        assertEquals("backend_has_no_active_incident", decision.reason)
        assertEquals(0, executeAndCountBackendCancels(decision))
    }

    @Test
    fun `session and device scope must still match exact incident`() {
        val wrongSession = ProtectionNativeSosCancelPolicy.evaluate(
            pending = pending(canonicalIncidentId = "incident-n"),
            activeBackendIncidentId = "incident-n",
            currentSessionScope = "account-b",
            currentDeviceId = "AA:BB:CC:DD:EE:FF",
            currentNodeId = 42,
        )
        val wrongDevice = ProtectionNativeSosCancelPolicy.evaluate(
            pending = pending(canonicalIncidentId = "incident-n"),
            activeBackendIncidentId = "incident-n",
            currentSessionScope = "account-a",
            currentDeviceId = "11:22:33:44:55:66",
            currentNodeId = 43,
        )

        assertEquals("session_scope_mismatch", wrongSession.reason)
        assertEquals("device_identity_mismatch", wrongDevice.reason)
        assertEquals(
            0,
            executeAndCountBackendCancels(wrongSession) +
                executeAndCountBackendCancels(wrongDevice),
        )
    }

    @Test
    fun `failed exact flush can retry while rejected flush never invokes transport`() {
        val accepted = evaluate(
            pending = pending(canonicalIncidentId = "incident-n"),
            activeIncidentId = "incident-n",
        )
        val rejected = evaluate(
            pending = pending(canonicalIncidentId = "incident-n"),
            activeIncidentId = "incident-n-plus-1",
        )
        var attempts = 0

        runCatching {
            ProtectionNativeSosCancelFlushGate.execute(accepted) {
                attempts += 1
                error("simulated transport failure")
            }
        }
        val retryOutcome = ProtectionNativeSosCancelFlushGate.execute(accepted) {
            attempts += 1
        }
        ProtectionNativeSosCancelFlushGate.execute(rejected) {
            attempts += 100
        }

        assertEquals(2, attempts)
        assertEquals(ProtectionNativeSosCancelOutcome.flushExecuted, retryOutcome)
    }

    private fun evaluate(
        pending: ProtectionPendingNativeSosCancel?,
        activeIncidentId: String?,
    ): ProtectionNativeSosCancelDecision =
        ProtectionNativeSosCancelPolicy.evaluate(
            pending = pending,
            activeBackendIncidentId = activeIncidentId,
            currentSessionScope = "account-a",
            currentDeviceId = "AA:BB:CC:DD:EE:FF",
            currentNodeId = 42,
        )

    private fun pending(canonicalIncidentId: String?): ProtectionPendingNativeSosCancel =
        ProtectionPendingNativeSosCancel(
            lifecycleId = "generation-n",
            canonicalBackendIncidentId = canonicalIncidentId,
            provisionalIncidentId = "local-generation-n",
            sessionScope = "account-a",
            deviceId = "AA:BB:CC:DD:EE:FF",
            nodeId = 42,
            createdAt = 1_000L,
            state = "pending",
            transportState = "not_attempted",
            ackState = "pending",
        )

    private fun executeAndCountBackendCancels(
        decision: ProtectionNativeSosCancelDecision,
    ): Int {
        var count = 0
        ProtectionNativeSosCancelFlushGate.execute(decision) {
            count += 1
        }
        return count
    }
}
