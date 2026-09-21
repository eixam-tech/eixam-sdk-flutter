package dev.eixam.connect.flutter.protection

internal object ProtectionBleRawPacketType {
    fun classify(
        payload: List<Int>,
        isSosCharacteristic: Boolean,
    ): String {
        if (payload.isEmpty()) {
            return "empty"
        }
        if (payload.size == 6 && payload.first() in setOf(0xE1, 0xE2, 0xE3)) {
            return "sos_event"
        }
        val flagsOffset = when (payload.size) {
            7, 10 -> 4
            12 -> 10
            else -> null
        }
        val flags = flagsOffset?.let { offset ->
            (payload[offset] and 0xFF) or ((payload[offset + 1] and 0xFF) shl 8)
        }
        val sosType = flags?.let { (it shr 14) and 0x03 }
        val hasSosWireShape = flags != null &&
            sosType != 0 &&
            (payload.size != 12 || flags and 0x0020 == 0)
        if (hasSosWireShape) {
            return "sos"
        }
        if (isSosCharacteristic && flags != null) {
            return "sos_clear"
        }
        return when (payload.first()) {
            0xE9 -> "device_status"
            0xD0 -> "tel_fragment"
            0xD1 -> "tel_backlog"
            0xD2 -> "d2_relay"
            0xD3 -> "tel_live_batch"
            else -> "unknown"
        }
    }
}
