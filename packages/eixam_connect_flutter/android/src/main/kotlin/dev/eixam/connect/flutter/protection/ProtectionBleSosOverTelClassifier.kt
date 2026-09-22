package dev.eixam.connect.flutter.protection

internal enum class ProtectionBleSosOverTelKind {
    ModernSos,
    Tel,
    Malformed,
}

internal data class ProtectionBleSosOverTelDecision(
    val kind: ProtectionBleSosOverTelKind,
    val reason: String,
    val sosType: Int? = null,
    val packetId: Int? = null,
    val originatorNodeId: Int? = null,
) {
    val isModernSos: Boolean
        get() = kind == ProtectionBleSosOverTelKind.ModernSos
}

/** Mirrors firmware `isSosOverTel()` for the evidence retained by BLE/D2. */
internal object ProtectionBleSosOverTelClassifier {
    fun classify(payload: List<Int>): ProtectionBleSosOverTelDecision {
        if (payload.size != 12) {
            return ProtectionBleSosOverTelDecision(
                kind = ProtectionBleSosOverTelKind.Malformed,
                reason = "invalid_12_byte_length",
            )
        }
        if (payload.any { it !in 0..0xFF }) {
            return ProtectionBleSosOverTelDecision(
                kind = ProtectionBleSosOverTelKind.Malformed,
                reason = "invalid_byte_domain",
            )
        }
        val flagsWord = payload[10] or (payload[11] shl 8)
        val sosType = (flagsWord shr 14) and 0x03
        val common = ProtectionBleSosOverTelDecision(
            kind = ProtectionBleSosOverTelKind.Tel,
            reason = "legacy_or_non_sos_without_hop_proof",
            sosType = sosType,
            packetId = flagsWord and 0x0F,
            originatorNodeId = readU32(payload),
        )
        if (flagsWord and 0x0020 != 0) {
            return common.copy(reason = "tel_position_format_bit_set")
        }
        if (sosType == 3) {
            return common.copy(
                kind = ProtectionBleSosOverTelKind.ModernSos,
                reason = "modern_sos_type_3",
            )
        }
        return common
    }

    private fun readU32(payload: List<Int>): Int =
        payload[0] or
            (payload[1] shl 8) or
            (payload[2] shl 16) or
            (payload[3] shl 24)
}
