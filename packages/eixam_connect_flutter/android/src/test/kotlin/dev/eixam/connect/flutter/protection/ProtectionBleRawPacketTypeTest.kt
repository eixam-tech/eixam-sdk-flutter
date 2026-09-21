package dev.eixam.connect.flutter.protection

import org.junit.Assert.assertEquals
import org.junit.Test

class ProtectionBleRawPacketTypeTest {
    private val firmwareFullSos = listOf(
        0xA8,
        0x1A,
        0x4B,
        0x59,
        0x48,
        0xCD,
        0x1B,
        0x34,
        0x44,
        0x28,
        0x00,
        0xC0,
    )

    @Test
    fun `actual firmware START is labeled SOS on EA01 and EA02`() {
        assertEquals(
            "sos",
            ProtectionBleRawPacketType.classify(
                payload = firmwareFullSos,
                isSosCharacteristic = false,
            ),
        )
        assertEquals(
            "sos",
            ProtectionBleRawPacketType.classify(
                payload = firmwareFullSos,
                isSosCharacteristic = true,
            ),
        )
    }

    @Test
    fun `firmware cancel replica is labeled SOS event on both characteristics`() {
        val cancel = listOf(0xE1, 0x02, 0xA8, 0x1A, 0x4B, 0x59)
        assertEquals(
            "sos_event",
            ProtectionBleRawPacketType.classify(cancel, isSosCharacteristic = false),
        )
        assertEquals(
            "sos_event",
            ProtectionBleRawPacketType.classify(cancel, isSosCharacteristic = true),
        )
    }

    @Test
    fun `ordinary 12-byte TEL position is not mislabeled SOS`() {
        val position = listOf(
            0xA8,
            0x1A,
            0x4B,
            0x59,
            0x48,
            0xCD,
            0x1B,
            0x34,
            0x44,
            0x28,
            0x20,
            0x40,
        )
        assertEquals(
            "unknown",
            ProtectionBleRawPacketType.classify(position, isSosCharacteristic = false),
        )
    }
}
