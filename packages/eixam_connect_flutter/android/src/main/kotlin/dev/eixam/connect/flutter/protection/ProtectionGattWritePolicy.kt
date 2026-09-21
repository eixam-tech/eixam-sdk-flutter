package dev.eixam.connect.flutter.protection

internal enum class ProtectionGattCharacteristicRole {
    inet,
    cmd,
}

internal object ProtectionGattWritePolicy {
    private val legacyInetFallbackOpcodes = setOf(0x04, 0x05, 0x06)

    fun selectCharacteristic(
        forceCmdCharacteristic: Boolean,
        payloadLength: Int,
        opcode: Int?,
        inetReady: Boolean,
        cmdReady: Boolean,
        inetMaxPayloadLength: Int,
    ): ProtectionGattCharacteristicRole? {
        val requiresCmd = forceCmdCharacteristic || payloadLength > inetMaxPayloadLength
        if (requiresCmd) {
            if (cmdReady) {
                return ProtectionGattCharacteristicRole.cmd
            }
            if (
                forceCmdCharacteristic &&
                payloadLength <= inetMaxPayloadLength &&
                opcode in legacyInetFallbackOpcodes &&
                inetReady
            ) {
                return ProtectionGattCharacteristicRole.inet
            }
            return null
        }
        return when {
            inetReady -> ProtectionGattCharacteristicRole.inet
            cmdReady -> ProtectionGattCharacteristicRole.cmd
            else -> null
        }
    }

    fun selectWriteWithResponse(
        supportsWrite: Boolean,
        supportsWriteWithoutResponse: Boolean,
    ): Boolean? = when {
        supportsWrite -> true
        supportsWriteWithoutResponse -> false
        else -> null
    }
}
