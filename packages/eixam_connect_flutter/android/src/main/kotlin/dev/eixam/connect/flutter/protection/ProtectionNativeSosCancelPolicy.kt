package dev.eixam.connect.flutter.protection

import java.util.Locale

internal data class ProtectionPendingNativeSosCancel(
    val lifecycleId: String?,
    val canonicalBackendIncidentId: String?,
    val provisionalIncidentId: String?,
    val sessionScope: String?,
    val deviceId: String?,
    val nodeId: Int?,
    val createdAt: Long,
    val state: String,
    val transportState: String,
    val ackState: String,
)

internal enum class ProtectionNativeSosCancelOutcome(
    val diagnosticCode: String,
) {
    pendingAccepted("NATIVE_SOS_CANCEL_PENDING_ACCEPTED"),
    pendingStaleRejected("NATIVE_SOS_CANCEL_PENDING_STALE_REJECTED"),
    incidentMismatch("NATIVE_SOS_CANCEL_INCIDENT_MISMATCH"),
    noCanonicalTarget("NATIVE_SOS_CANCEL_NO_CANONICAL_TARGET"),
    flushExecuted("NATIVE_SOS_CANCEL_FLUSH_EXECUTED"),
}

internal data class ProtectionNativeSosCancelDecision(
    val outcome: ProtectionNativeSosCancelOutcome,
    val executeBackendCancel: Boolean,
    val reason: String,
)

internal object ProtectionNativeSosCancelPolicy {
    fun evaluate(
        pending: ProtectionPendingNativeSosCancel?,
        activeBackendIncidentId: String?,
        currentSessionScope: String?,
        currentDeviceId: String?,
        currentNodeId: Int?,
    ): ProtectionNativeSosCancelDecision {
        if (pending == null) {
            return rejectStale("legacy_record_without_identity")
        }
        if (pending.lifecycleId.isNullOrBlank()) {
            return rejectStale("missing_lifecycle_identity")
        }
        val canonicalIncidentId = pending.canonicalBackendIncidentId
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: return ProtectionNativeSosCancelDecision(
                outcome = ProtectionNativeSosCancelOutcome.noCanonicalTarget,
                executeBackendCancel = false,
                reason = "missing_canonical_incident",
            )
        val storedSessionScope = pending.sessionScope?.trim()
        val effectiveSessionScope = currentSessionScope?.trim()
        if (storedSessionScope.isNullOrEmpty() || effectiveSessionScope.isNullOrEmpty()) {
            return rejectStale("missing_session_scope")
        }
        if (storedSessionScope != effectiveSessionScope) {
            return rejectStale("session_scope_mismatch")
        }
        if (!sameDeviceIdentity(
                pendingDeviceId = pending.deviceId,
                pendingNodeId = pending.nodeId,
                currentDeviceId = currentDeviceId,
                currentNodeId = currentNodeId,
            )
        ) {
            return rejectStale("device_identity_mismatch")
        }
        val activeIncidentId = activeBackendIncidentId
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: return rejectStale("backend_has_no_active_incident")
        if (canonicalIncidentId != activeIncidentId) {
            return ProtectionNativeSosCancelDecision(
                outcome = ProtectionNativeSosCancelOutcome.incidentMismatch,
                executeBackendCancel = false,
                reason = "canonical_incident_mismatch",
            )
        }
        return ProtectionNativeSosCancelDecision(
            outcome = ProtectionNativeSosCancelOutcome.pendingAccepted,
            executeBackendCancel = true,
            reason = "exact_incident_match",
        )
    }

    private fun rejectStale(reason: String): ProtectionNativeSosCancelDecision =
        ProtectionNativeSosCancelDecision(
            outcome = ProtectionNativeSosCancelOutcome.pendingStaleRejected,
            executeBackendCancel = false,
            reason = reason,
        )

    private fun sameDeviceIdentity(
        pendingDeviceId: String?,
        pendingNodeId: Int?,
        currentDeviceId: String?,
        currentNodeId: Int?,
    ): Boolean {
        if (pendingNodeId != null && currentNodeId != null) {
            return pendingNodeId == currentNodeId
        }
        val pendingDevice = pendingDeviceId?.trim()?.uppercase(Locale.US)
        val currentDevice = currentDeviceId?.trim()?.uppercase(Locale.US)
        return !pendingDevice.isNullOrEmpty() &&
            !currentDevice.isNullOrEmpty() &&
            pendingDevice == currentDevice
    }
}

internal object ProtectionNativeSosCancelFlushGate {
    fun execute(
        decision: ProtectionNativeSosCancelDecision,
        cancelBackend: () -> Unit,
    ): ProtectionNativeSosCancelOutcome {
        if (!decision.executeBackendCancel) {
            return decision.outcome
        }
        cancelBackend()
        return ProtectionNativeSosCancelOutcome.flushExecuted
    }
}
