package dev.eixam.connect.flutter.protection

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

    fun classify(
        payload: List<Int>,
        connectedNodeId: Int?,
        source: ProtectionBleSosRelaySource,
    ): ProtectionBleSosIdentityClassification {
        val eventPacket = tryParseEventPacket(payload)
        if (eventPacket != null) {
            if (connectedNodeId != null && eventPacket.nodeId != connectedNodeId) {
                return ProtectionBleSosIdentityClassification.RemoteEvent(
                    originatorNodeId = eventPacket.nodeId,
                    relayNodeId = connectedNodeId,
                    source = source,
                    rawPayload = payload,
                )
            }
            return ProtectionBleSosIdentityClassification.OwnEvent
        }

        val sosPacket = tryParseSosPacket(payload) ?: return ProtectionBleSosIdentityClassification.Unknown
        if (sosPacket.sosType == 0) {
            return ProtectionBleSosIdentityClassification.Unknown
        }
        if (connectedNodeId == null || sosPacket.nodeId == connectedNodeId) {
            return ProtectionBleSosIdentityClassification.OwnSos
        }
        return ProtectionBleSosIdentityClassification.RemoteSos(
            originatorNodeId = sosPacket.nodeId,
            relayNodeId = connectedNodeId,
            source = source,
            rawPayload = payload,
        )
    }

    private fun tryParseSosPacket(payload: List<Int>): SosPacket? {
        if (payload.size != 7 && payload.size != 12) {
            return null
        }
        val flagsOffset = if (payload.size == 12) 10 else 4
        val flagsWord = payload[flagsOffset] or (payload[flagsOffset + 1] shl 8)
        return SosPacket(
            nodeId = readU32(payload, 0),
            sosType = (flagsWord shr 14) and 0x03,
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

    private data class SosPacket(
        val nodeId: Int,
        val sosType: Int,
    )

    private data class EventPacket(
        val nodeId: Int,
    )
}

internal enum class ProtectionBleSosRelaySource {
    sos,
    tel,
}

internal sealed class ProtectionBleSosIdentityClassification {
    data object Unknown : ProtectionBleSosIdentityClassification()
    data object OwnSos : ProtectionBleSosIdentityClassification()
    data object OwnEvent : ProtectionBleSosIdentityClassification()

    data class RemoteSos(
        val originatorNodeId: Int,
        val relayNodeId: Int,
        val source: ProtectionBleSosRelaySource,
        val rawPayload: List<Int>,
    ) : ProtectionBleSosIdentityClassification()

    data class RemoteEvent(
        val originatorNodeId: Int,
        val relayNodeId: Int,
        val source: ProtectionBleSosRelaySource,
        val rawPayload: List<Int>,
    ) : ProtectionBleSosIdentityClassification()
}
