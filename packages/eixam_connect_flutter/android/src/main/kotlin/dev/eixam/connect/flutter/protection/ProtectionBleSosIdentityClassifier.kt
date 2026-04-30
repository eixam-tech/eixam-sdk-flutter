package dev.eixam.connect.flutter.protection

import java.util.Locale

internal object ProtectionBleSosIdentityClassifier {
    fun tryParseDeviceRuntimeNodeId(payload: List<Int>): Int? {
        if (payload.size != 14) {
            return null
        }
        if (payload[0] != 0xE9 || payload[1] != 0x78 || payload[2] != 0x02) {
            return null
        }
        return readU32(payload, 7)
    }

    @Suppress("UNUSED_PARAMETER")
    fun classify(
        payload: List<Int>,
        connectedNodeId: Int?,
        // Metadata only unless it is tied to the active BLE notification source.
        boundNodeId: Int? = null,
        boundDeviceId: String? = null,
        activeBleHardwareId: String? = null,
        activeRuntimeDeviceId: String? = null,
        bleLinkActive: Boolean = false,
        cmdReady: Boolean = false,
        source: ProtectionBleSosRelaySource,
    ): ProtectionBleSosIdentityClassification {
        val eventPacket = tryParseEventPacket(payload)
        if (eventPacket != null) {
            val identity = resolveIdentityProof(
                originatorNodeId = eventPacket.nodeId,
                strictConnectedBleNodeId = connectedNodeId,
                boundNodeId = boundNodeId,
                boundDeviceId = boundDeviceId,
                activeBleHardwareId = activeBleHardwareId,
                activeRuntimeDeviceId = activeRuntimeDeviceId,
                bleLinkActive = bleLinkActive,
            )
            if (identity.localNodeId == null) {
                return ProtectionBleSosIdentityClassification.UnknownOriginEvent(
                    originatorNodeId = eventPacket.nodeId,
                    source = source,
                    rawPayload = payload,
                    identityProof = identity.identityProof,
                    reason = identity.reason,
                )
            }
            if (eventPacket.nodeId != identity.localNodeId) {
                return ProtectionBleSosIdentityClassification.RemoteEvent(
                    originatorNodeId = eventPacket.nodeId,
                    relayNodeId = identity.localNodeId,
                    source = source,
                    rawPayload = payload,
                    identityProof = identity.identityProof,
                    reason = identity.remoteReason,
                )
            }
            return ProtectionBleSosIdentityClassification.OwnEvent(
                identityProof = identity.identityProof,
                reason = identity.reason,
            )
        }

        val sosPacket = tryParseSosPacket(payload) ?: return ProtectionBleSosIdentityClassification.Unknown
        if (sosPacket.sosType == 0) {
            return ProtectionBleSosIdentityClassification.Unknown
        }
        val identity = resolveIdentityProof(
            originatorNodeId = sosPacket.nodeId,
            strictConnectedBleNodeId = connectedNodeId,
            boundNodeId = boundNodeId,
            boundDeviceId = boundDeviceId,
            activeBleHardwareId = activeBleHardwareId,
            activeRuntimeDeviceId = activeRuntimeDeviceId,
            bleLinkActive = bleLinkActive,
        )
        if (identity.localNodeId == null) {
            return ProtectionBleSosIdentityClassification.UnknownOriginSos(
                originatorNodeId = sosPacket.nodeId,
                source = source,
                rawPayload = payload,
                sosType = sosPacket.sosType,
                position = sosPacket.position,
                identityProof = identity.identityProof,
                reason = identity.reason,
            )
        }
        if (sosPacket.nodeId == identity.localNodeId) {
            return ProtectionBleSosIdentityClassification.OwnSos(
                identityProof = identity.identityProof,
                reason = identity.reason,
            )
        }
        return ProtectionBleSosIdentityClassification.RemoteSos(
            originatorNodeId = sosPacket.nodeId,
            relayNodeId = identity.localNodeId,
            source = source,
            rawPayload = payload,
            sosType = sosPacket.sosType,
            position = sosPacket.position,
            identityProof = identity.identityProof,
            reason = identity.remoteReason,
        )
    }

    private fun resolveIdentityProof(
        originatorNodeId: Int,
        strictConnectedBleNodeId: Int?,
        boundNodeId: Int?,
        boundDeviceId: String?,
        activeBleHardwareId: String?,
        activeRuntimeDeviceId: String?,
        bleLinkActive: Boolean,
    ): IdentityDecision {
        if (strictConnectedBleNodeId != null) {
            return IdentityDecision(
                localNodeId = strictConnectedBleNodeId,
                identityProof = IdentityProof.StrictConnectedNode,
                reason = "originator_matches_connected_ble_node",
                remoteReason = "originator_differs_from_connected_ble_node",
            )
        }

        val normalizedActive = normalizeHardwareId(activeBleHardwareId)
        val normalizedBound = normalizeHardwareId(boundDeviceId)
        val normalizedRuntime = normalizeHardwareId(activeRuntimeDeviceId)
        val activeHardwareMatchesBound =
            normalizedActive != null &&
                normalizedBound != null &&
                normalizedRuntime != null &&
                normalizedActive == normalizedBound &&
                normalizedActive == normalizedRuntime

        if (activeHardwareMatchesBound && bleLinkActive && boundNodeId != null) {
            return IdentityDecision(
                localNodeId = boundNodeId,
                identityProof = IdentityProof.ActiveBleHardwareId,
                reason = "active_ble_hardware_originator_matches_bound_node",
                remoteReason = "originator_differs_from_active_ble_hardware_bound_node",
            )
        }

        if (boundNodeId == originatorNodeId) {
            return IdentityDecision(
                localNodeId = null,
                identityProof = IdentityProof.MetadataOnly,
                reason = "metadata_only_bound_node_not_identity_proof",
                remoteReason = "metadata_only_bound_node_not_identity_proof",
            )
        }

        return IdentityDecision(
            localNodeId = null,
            identityProof = IdentityProof.None,
            reason = "no_identity_proof",
            remoteReason = "no_identity_proof",
        )
    }

    private fun normalizeHardwareId(value: String?): String? =
        value?.trim()?.uppercase(Locale.US)?.takeIf { it.isNotBlank() }

    private fun tryParseSosPacket(payload: List<Int>): SosPacket? {
        if (payload.size != 7 && payload.size != 12) {
            return null
        }
        val flagsOffset = if (payload.size == 12) 10 else 4
        val flagsWord = payload[flagsOffset] or (payload[flagsOffset + 1] shl 8)
        return SosPacket(
            nodeId = readU32(payload, 0),
            sosType = (flagsWord shr 14) and 0x03,
            position = if (payload.size == 12) decodePosition(payload, 4) else null,
        )
    }

    private fun tryParseEventPacket(payload: List<Int>): EventPacket? {
        if (payload.size != 6) {
            return null
        }
        val opcode = payload[0] and 0xFF
        val subcode = payload[1] and 0xFF
        if (opcode != 0xE1 && opcode != 0xE2) {
            return null
        }
        if (subcode !in 0x01..0x03) {
            return null
        }
        return EventPacket(nodeId = readU32(payload, 2))
    }

    private fun readU32(payload: List<Int>, offset: Int): Int =
        (payload[offset] and 0xFF) or
            ((payload[offset + 1] and 0xFF) shl 8) or
            ((payload[offset + 2] and 0xFF) shl 16) or
            ((payload[offset + 3] and 0xFF) shl 24)

    private fun decodePosition(payload: List<Int>, offset: Int): SosPosition {
        val packed =
            ((payload[offset] and 0xFF).toLong()) or
                ((payload[offset + 1] and 0xFF).toLong() shl 8) or
                ((payload[offset + 2] and 0xFF).toLong() shl 16) or
                ((payload[offset + 3] and 0xFF).toLong() shl 24) or
                ((payload[offset + 4] and 0xFF).toLong() shl 32) or
                ((payload[offset + 5] and 0xFF).toLong() shl 40)
        val latEnc = packed and 0xFFFFF
        val lonEnc = (packed shr 20) and 0x1FFFFF
        val altEnc = (packed shr 41) and 0x7F
        return SosPosition(
            latitude = (latEnc * 180.0 / 1048576.0) - 90.0,
            longitude = (lonEnc * 360.0 / 2097152.0) - 180.0,
            altitude = (altEnc * 40).toDouble(),
        )
    }

    private data class SosPacket(
        val nodeId: Int,
        val sosType: Int,
        val position: ProtectionBleSosIdentityClassifier.SosPosition?,
    )

    data class SosPosition(
        val latitude: Double,
        val longitude: Double,
        val altitude: Double,
    )

    private data class EventPacket(
        val nodeId: Int,
    )

    private data class IdentityDecision(
        val localNodeId: Int?,
        val identityProof: IdentityProof,
        val reason: String,
        val remoteReason: String,
    )
}

internal enum class IdentityProof(val logValue: String) {
    StrictConnectedNode("strict_connected_node"),
    ActiveBleHardwareId("active_ble_hardware_id"),
    MetadataOnly("metadata_only"),
    None("none"),
}

internal enum class ProtectionBleSosRelaySource {
    sos,
    tel,
    d2,
}

internal sealed class ProtectionBleSosIdentityClassification {
    open val identityProof: IdentityProof = IdentityProof.None
    open val reason: String = "no_identity_proof"

    data object Unknown : ProtectionBleSosIdentityClassification()
    data class OwnSos(
        override val identityProof: IdentityProof,
        override val reason: String,
    ) : ProtectionBleSosIdentityClassification()

    data class OwnEvent(
        override val identityProof: IdentityProof,
        override val reason: String,
    ) : ProtectionBleSosIdentityClassification()

    data class UnknownOriginSos(
        val originatorNodeId: Int,
        val source: ProtectionBleSosRelaySource,
        val rawPayload: List<Int>,
        val sosType: Int,
        val position: ProtectionBleSosIdentityClassifier.SosPosition?,
        override val identityProof: IdentityProof,
        override val reason: String,
    ) : ProtectionBleSosIdentityClassification()

    data class UnknownOriginEvent(
        val originatorNodeId: Int,
        val source: ProtectionBleSosRelaySource,
        val rawPayload: List<Int>,
        override val identityProof: IdentityProof,
        override val reason: String,
    ) : ProtectionBleSosIdentityClassification()

    data class RemoteSos(
        val originatorNodeId: Int,
        val relayNodeId: Int,
        val source: ProtectionBleSosRelaySource,
        val rawPayload: List<Int>,
        val sosType: Int,
        val position: ProtectionBleSosIdentityClassifier.SosPosition?,
        override val identityProof: IdentityProof,
        override val reason: String,
    ) : ProtectionBleSosIdentityClassification()

    data class RemoteEvent(
        val originatorNodeId: Int,
        val relayNodeId: Int,
        val source: ProtectionBleSosRelaySource,
        val rawPayload: List<Int>,
        override val identityProof: IdentityProof,
        override val reason: String,
    ) : ProtectionBleSosIdentityClassification()
}
