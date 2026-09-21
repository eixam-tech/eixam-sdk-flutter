package dev.eixam.connect.flutter.protection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtectionGattWritePolicyTest {
    @Test
    fun `app SOS selects CMD when both physical characteristics are ready`() {
        val selected =
            ProtectionGattWritePolicy.selectCharacteristic(
                forceCmdCharacteristic = true,
                payloadLength = 1,
                opcode = 0x06,
                inetReady = true,
                cmdReady = true,
                inetMaxPayloadLength = 4,
            )

        assertEquals(ProtectionGattCharacteristicRole.cmd, selected)
    }

    @Test
    fun `app SOS falls back to legacy INET only when CMD is absent`() {
        val selected =
            ProtectionGattWritePolicy.selectCharacteristic(
                forceCmdCharacteristic = true,
                payloadLength = 1,
                opcode = 0x06,
                inetReady = true,
                cmdReady = false,
                inetMaxPayloadLength = 4,
            )

        assertEquals(ProtectionGattCharacteristicRole.inet, selected)
    }

    @Test
    fun `non SOS forced command does not fall back from CMD`() {
        val selected =
            ProtectionGattWritePolicy.selectCharacteristic(
                forceCmdCharacteristic = true,
                payloadLength = 1,
                opcode = 0x22,
                inetReady = true,
                cmdReady = false,
                inetMaxPayloadLength = 4,
            )

        assertNull(selected)
    }

    @Test
    fun `write with response is preferred and unsupported properties reject`() {
        assertTrue(
            ProtectionGattWritePolicy.selectWriteWithResponse(
                supportsWrite = true,
                supportsWriteWithoutResponse = true,
            )!!,
        )
        assertFalse(
            ProtectionGattWritePolicy.selectWriteWithResponse(
                supportsWrite = false,
                supportsWriteWithoutResponse = true,
            )!!,
        )
        assertNull(
            ProtectionGattWritePolicy.selectWriteWithResponse(
                supportsWrite = false,
                supportsWriteWithoutResponse = false,
            ),
        )
    }
}
